#include "research/xeno/labs/foresight/launch_agent/proto/rag_service.grpc.pb.h"
#include "helper_control.grpc.pb.h"
#include <grpcpp/grpcpp.h>
#include <sqlite3.h>
#include <nlohmann/json.hpp>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <cmath>
#include <algorithm>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <chrono>
#include "model.h"
#include "vector_index.h"
#include <atomic>
#include <cctype>
using json=nlohmann::json;
namespace rpc=research::xeno::labs::foresight::launch_agent::proto;
namespace ctl=foresight::linux::control::v1;
namespace fs=std::filesystem;
using grpc::Status; using grpc::StatusCode;
struct Statement {
 sqlite3_stmt* p=nullptr;
 Statement(sqlite3* db,const char* sql){if(sqlite3_prepare_v2(db,sql,-1,&p,nullptr)!=SQLITE_OK)throw std::runtime_error(sqlite3_errmsg(db));}
 ~Statement(){sqlite3_finalize(p);}
 void text(int n,const std::string& v){sqlite3_bind_text(p,n,v.data(),v.size(),SQLITE_TRANSIENT);}
 void num(int n,int64_t v){sqlite3_bind_int64(p,n,v);}
 void blob(int n,const std::string& v){sqlite3_bind_blob(p,n,v.data(),v.size(),SQLITE_TRANSIENT);}
 bool row(){int r=sqlite3_step(p);if(r!=SQLITE_ROW&&r!=SQLITE_DONE)throw std::runtime_error(sqlite3_errmsg(sqlite3_db_handle(p)));return r==SQLITE_ROW;}
 std::string str(int n){const auto* b=sqlite3_column_blob(p,n);return b?std::string((const char*)b,sqlite3_column_bytes(p,n)):"";}
 int64_t integer(int n){return sqlite3_column_int64(p,n);}
};
class Service:public rpc::RagService::Service,public ctl::HelperControl::Service {
 struct SearchSnapshot { std::shared_ptr<Model> model; foresight::VectorIndex index; SearchSnapshot(std::shared_ptr<Model> m,std::vector<foresight::IndexedChunk> chunks):model(std::move(m)),index(std::move(chunks)){} };
 std::shared_ptr<const SearchSnapshot> search_snapshot; std::mutex snapshot_mu;
 void publish_index() {
  std::vector<foresight::IndexedChunk> chunks;
  Statement q(db,"SELECT c.text,c.document_id,c.mime,c.embedding FROM vectors.chunks c JOIN linux.source_revisions r ON r.id=c.document_id AND r.revision=c.revision WHERE r.tombstone=0 AND c.generation=? ORDER BY c.document_id,c.ordinal");q.num(1,state.active_generation());
  while(q.row()) chunks.push_back({q.str(0),q.str(1),q.str(2),foresight::read_vector(q.str(3))});
  std::shared_ptr<const SearchSnapshot> replacement=std::make_shared<SearchSnapshot>(model,std::move(chunks));
  {std::lock_guard lock(snapshot_mu);search_snapshot.swap(replacement);}
  // Retire the old tree outside the pointer lock; destruction can be expensive.
 }
 struct PreparedChunk { std::string text; std::vector<double> embedding; };
 struct DocWork { std::string id, content, mime; int size=0, overlap=0; uint64_t rev=0; std::vector<PreparedChunk> chunks; };
 sqlite3* db=nullptr; std::recursive_mutex mu; std::mutex view_mu, reconfig_mu; std::condition_variable reconfig_cv; bool reconfiguring=false; std::shared_ptr<Model> model;ctl::State state,view;bool allow_test,use_gpu=false;std::string path,cache,storage_root;
 struct ReconfigGuard { Service& s; bool held=false; explicit ReconfigGuard(Service& x):s(x){} void enter(){std::unique_lock lock(s.reconfig_mu); s.reconfig_cv.wait(lock,[&]{return !s.reconfiguring;}); s.reconfiguring=true; held=true;} ~ReconfigGuard(){if(!held)return; std::lock_guard lock(s.reconfig_mu); s.reconfiguring=false; s.reconfig_cv.notify_all();} };
 void sql(const std::string& q){char* e=nullptr;if(sqlite3_exec(db,q.c_str(),nullptr,nullptr,&e)!=SQLITE_OK){std::string msg=e?e:"SQLite failure";sqlite3_free(e);throw std::runtime_error(msg);}}
 struct Tx {Service& s;bool done=false;Tx(Service& x):s(x){s.sql("BEGIN IMMEDIATE");}~Tx(){if(!done)sqlite3_exec(s.db,"ROLLBACK",nullptr,nullptr,nullptr);}void commit(){s.sql("COMMIT");done=true;}};
 void changed(){state.set_revision(state.revision()+1);std::lock_guard lock(view_mu);view=state;}
 void crash(const char* step){if(!allow_test)return;
  // Test-only publication barrier: prove active readers never wait on the
  // writer's SQLite transaction or on construction of its replacement index.
  std::string pause;{std::ifstream file(storage_root+"/.pause-at");std::getline(file,pause);}
  if(pause==step){std::ofstream(storage_root+"/.paused")<<step;for(int i=0;i<100&&fs::exists(storage_root+"/.pause-at");++i)std::this_thread::sleep_for(std::chrono::milliseconds(50));}
std::string value;std::ifstream in(storage_root+"/.crash-at");std::getline(in,value);const char* env=getenv("FORESIGHT_CRASH_AT");if(value==step||(env&&std::string(env)==step))_exit(86);}
 uint64_t revision(const std::string& id){Statement q(db,"SELECT revision FROM linux.source_revisions WHERE id=?");q.text(1,id);return q.row()?q.integer(0)+1:1;}
 void journal(const std::string& op,const std::string& id,uint64_t rev){Statement q(db,"INSERT INTO linux.journal(operation,document_id,revision,generation,status) VALUES(?,?,?,?, 'committed')");q.text(1,op);q.text(2,id);q.num(3,rev);q.num(4,state.active_generation());q.row();}
 std::vector<PreparedChunk> prepare_chunks(Model& m,const std::string& content,int size,int overlap,const std::string& mime,grpc::ServerContext* context){
  if(mime.starts_with("image/"))throw std::runtime_error("Image embedding unavailable in text-only model");auto texts=m.chunks(content,size,overlap);std::vector<PreparedChunk> prepared;prepared.reserve(texts.size());
  for(size_t i=0;i<texts.size();++i){if(context && context->IsCancelled())throw std::runtime_error("Index operation cancelled");prepared.push_back({texts[i], m.embed(texts[i])});}
  return prepared;
 }
 void insert_vectors(const std::vector<PreparedChunk>& chunks,const std::string& id,uint64_t rev,uint64_t gen,const std::string& mime,grpc::ServerContext* context){
  // Foreground insertion is grouped in five-chunk batches, inside one atomic publication.
  for(size_t batch=0;batch<chunks.size();batch+=5)for(size_t i=batch;i<std::min(chunks.size(),batch+5);++i){if(context && context->IsCancelled())throw std::runtime_error("Index operation cancelled");Statement q(db,"INSERT INTO vectors.chunks(generation,document_id,revision,ordinal,text,mime,embedding) VALUES(?,?,?,?,?,?,?)");q.num(1,gen);q.text(2,id);q.num(3,rev);q.num(4,i);q.text(5,chunks[i].text);q.text(6,mime);q.blob(7,foresight::vector_blob(chunks[i].embedding));q.row();crash("partial_vectors");}
 }
 void note_adapter_failure(const std::shared_ptr<Model>& current,const std::exception& e){if(model==current && current && !current->available() && state.pipeline()=="ready"){state.set_pipeline("failed");state.set_tokenizer_ready(false);state.set_index("degraded");state.set_last_error(e.what());changed();}}
 void refresh_model_health(){std::unique_lock lock(mu,std::try_to_lock);if(lock.owns_lock()&&model&&!model->available()&&state.pipeline()=="ready"){state.set_pipeline("failed");state.set_tokenizer_ready(false);state.set_index("degraded");state.set_last_error("Embedding adapter exited; reload the model");changed();}}
 Status absent(){refresh_model_health();return {StatusCode::UNAVAILABLE,model?"Embedding adapter unavailable; reload the model":"Pipeline not initialized"};}
 template<class Response> Status app_error(Response* r,const std::exception& e){r->set_success(false);r->set_error_message(e.what());state.set_last_error(e.what());changed();return Status::OK;}
 std::string model_identity(const Model& m) {
  return json({"index-model-v1", m.digest, m.tokenizer_digest,
               m.test ? "test-only-byte-tokenizer/fnv-word-v1" : m.preprocessing,
               m.backend, m.dimensions}).dump();
 }
 void publish_model(std::shared_ptr<Model> replacement, const std::string& next,
                    const std::string& next_cache, bool next_gpu, uint64_t gen) {
  cache=next_cache;use_gpu=next_gpu;model=std::move(replacement);path=next;
  state.set_active_generation(gen);state.set_pending_generation(0);
  state.set_pipeline("ready");state.set_tokenizer_ready(true);
  state.set_index(state.completed()?"ready":"empty");state.set_last_error("");
  auto* identity=state.mutable_model();identity->set_model_digest(model->digest);
  identity->set_tokenizer_digest(model->tokenizer_digest);
  identity->set_preprocessing(model->test?"test-only-byte-tokenizer/fnv-word-v1":model->preprocessing);
  identity->set_backend(model->backend);identity->set_dimensions(model->dimensions);
  publish_index();
  identity->set_path(path);identity->clear_modalities();identity->add_modalities("text");changed();
 }
 bool restore_vectors(const Model& replacement, const std::string& next,
                      const std::string& next_cache, bool next_gpu) {
  if(next!=path || next_cache!=cache || next_gpu!=use_gpu || !state.active_generation())return false;
  Statement identity(db,"SELECT value FROM settings WHERE key='index_model_identity'");
  if(!identity.row() || identity.str(0)!=model_identity(replacement))return false;
  Statement generation(db,"SELECT model_digest FROM vectors.generations WHERE id=? AND status='active'");
  generation.num(1,state.active_generation());
  if(!generation.row() || generation.str(0)!=replacement.digest)return false;
  Statement count(db,"SELECT COUNT(*) FROM documents d JOIN linux.source_revisions r ON r.id=d.id WHERE r.tombstone=0");
  count.row();state.set_attempted(count.integer(0));state.set_completed(count.integer(0));
  return true;
 }
public:
 Service(const std::string& root,bool allow):allow_test(allow),storage_root(root){
  if(sqlite3_open((root+"/agent_metadata.db").c_str(),&db)!=SQLITE_OK)throw std::runtime_error("Cannot open metadata");sqlite3_busy_timeout(db,5000);
  sql("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL");
  sql("CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY,content TEXT,userId TEXT,maxTokensPerChunk INTEGER,chunkOverlap INTEGER,mimeType TEXT,imageBytes BLOB); CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT)");
  {Statement a(db,"ATTACH DATABASE ? AS linux");a.text(1,root+"/linux_state.db");a.row();}
  sql("PRAGMA linux.journal_mode=DELETE; PRAGMA linux.synchronous=FULL; CREATE TABLE IF NOT EXISTS linux.source_revisions(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,tombstone INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS linux.journal(sequence INTEGER PRIMARY KEY,operation TEXT,document_id TEXT,revision INTEGER,generation INTEGER,status TEXT)");
  {Statement a(db,"ATTACH DATABASE ? AS vectors");a.text(1,root+"/rag_vector.db");a.row();}
  sql("PRAGMA vectors.journal_mode=DELETE; PRAGMA vectors.synchronous=FULL; CREATE TABLE IF NOT EXISTS vectors.chunks(generation INTEGER,document_id TEXT,revision INTEGER,ordinal INTEGER,text TEXT,mime TEXT,embedding BLOB,PRIMARY KEY(generation,document_id,revision,ordinal)); CREATE TABLE IF NOT EXISTS vectors.generations(id INTEGER PRIMARY KEY,model_digest TEXT,status TEXT)");
  // Migrate legacy JSON once at startup; requests only consume binary snapshots.
  { Tx tx(*this); Statement rows(db,"SELECT rowid,embedding FROM vectors.chunks WHERE typeof(embedding)='text'");
    while(rows.row()){auto bytes=foresight::vector_blob(json::parse(rows.str(1)).get<std::vector<double>>());Statement update(db,"UPDATE vectors.chunks SET embedding=? WHERE rowid=?");update.blob(1,bytes);update.num(2,rows.integer(0));update.row();} tx.commit(); }
  sql("INSERT OR IGNORE INTO linux.source_revisions SELECT id,1,0 FROM documents; DELETE FROM vectors.chunks WHERE NOT EXISTS (SELECT 1 FROM linux.source_revisions r WHERE r.id=chunks.document_id AND r.revision=chunks.revision AND r.tombstone=0); DELETE FROM vectors.chunks WHERE generation IN(SELECT id FROM vectors.generations WHERE status!='active'); DELETE FROM vectors.generations WHERE status!='active'");
  state.set_build_id(FORESIGHT_BUILD_ID);state.set_reference_version("1.0.3");state.set_instance_id(std::to_string(getpid())+"-"+std::to_string(std::chrono::system_clock::now().time_since_epoch().count()));state.set_pipeline("unconfigured");state.set_index("empty");state.set_revision(1);state.set_totals_known(true);
  Statement q(db,"SELECT value FROM settings WHERE key='embedding_model_path'");if(q.row())path=q.str(0);
  {Statement c(db,"SELECT value FROM settings WHERE key='cache_dir'");if(c.row())cache=c.str(0);}
  {Statement g(db,"SELECT value FROM settings WHERE key='use_gpu'");if(g.row())use_gpu=g.str(0)=="true";}
  Statement g(db,"SELECT id FROM vectors.generations WHERE status='active'");if(g.row()){state.set_active_generation(g.integer(0));state.set_index("degraded");}
  changed();
 }
 ~Service(){sqlite3_close(db);}
 Status Ping(grpc::ServerContext*,const rpc::PingRequest*,rpc::PingResponse* r)override{r->set_success(true);r->set_version("1.0.3");return Status::OK;}
 Status UpdateModelPaths(grpc::ServerContext* context,const rpc::UpdateModelPathsRequest* req,rpc::UpdateModelPathsResponse* r)override{ReconfigGuard guard(*this);try{guard.enter();std::string next,next_cache;bool next_gpu=false;{std::lock_guard lock(mu);next=req->embedding_model_path().empty()?path:req->embedding_model_path();next_cache=req->cache_dir().empty()?cache:req->cache_dir();next_gpu=req->has_use_gpu()?req->use_gpu():(req->embedding_model_path().empty()?use_gpu:false);if(!req->sentence_piece_model_path().empty())throw std::runtime_error("External SentencePiece unsupported: tokenizer is owned by the registered embedding model");if(context->IsCancelled())throw std::runtime_error("Model configuration cancelled");state.set_pipeline("loading");state.set_index("building");state.set_attempted(0);state.set_completed(0);state.set_failed(0);changed();}
  auto replacement=std::make_shared<Model>(next,allow_test,next_gpu);replacement->embed("readiness probe");if(context->IsCancelled())throw std::runtime_error("Model configuration cancelled");
  {std::lock_guard lock(mu);if(context->IsCancelled())throw std::runtime_error("Model configuration cancelled");if(restore_vectors(*replacement,next,next_cache,next_gpu)){publish_model(replacement,next,next_cache,next_gpu,state.active_generation());r->set_success(true);return Status::OK;}}
  std::vector<DocWork> docs;{std::lock_guard lock(mu);Statement rows(db,"SELECT d.id,d.content,d.maxTokensPerChunk,d.chunkOverlap,d.mimeType,r.revision FROM documents d JOIN linux.source_revisions r ON r.id=d.id WHERE r.tombstone=0");while(rows.row()){DocWork doc;doc.id=rows.str(0);doc.content=rows.str(1);doc.size=rows.integer(2);doc.overlap=rows.integer(3);doc.mime=rows.str(4);doc.rev=rows.integer(5);docs.push_back(std::move(doc));}}
  for(auto& doc:docs){if(context->IsCancelled())throw std::runtime_error("Model configuration cancelled");doc.chunks=prepare_chunks(*replacement,doc.content,doc.size,doc.overlap,doc.mime,context);}
  std::lock_guard lock(mu);if(context->IsCancelled())throw std::runtime_error("Model configuration cancelled");uint64_t gen=state.active_generation()+1;state.set_pending_generation(gen);changed();
  Tx tx(*this);{Statement q(db,"INSERT INTO vectors.generations VALUES(?,?,'building')");q.num(1,gen);q.text(2,replacement->digest);q.row();}
  for(auto& doc:docs){state.set_attempted(state.attempted()+1);insert_vectors(doc.chunks,doc.id,doc.rev,gen,doc.mime,context);state.set_completed(state.completed()+1);changed();}
  sql("DELETE FROM vectors.chunks WHERE generation != "+std::to_string(gen));sql("DELETE FROM vectors.generations WHERE id != "+std::to_string(gen));sql("UPDATE vectors.generations SET status='active' WHERE id="+std::to_string(gen));
  {Statement q(db,"INSERT OR REPLACE INTO settings VALUES('embedding_model_path',?)");q.text(1,next);q.row();}{Statement q(db,"INSERT OR REPLACE INTO settings VALUES('cache_dir',?)");q.text(1,next_cache);q.row();}{Statement g(db,"INSERT OR REPLACE INTO settings VALUES('use_gpu',?)");g.text(1,next_gpu?"true":"false");g.row();}{Statement identity(db,"INSERT OR REPLACE INTO settings VALUES('index_model_identity',?)");identity.text(1,model_identity(*replacement));identity.row();}crash("model_before_commit");if(context->IsCancelled())throw std::runtime_error("Model configuration cancelled");tx.commit();publish_model(replacement,next,next_cache,next_gpu,gen);r->set_success(true);return Status::OK;
 }catch(const std::exception& e){std::lock_guard lock(mu);state.set_pending_generation(0);state.set_failed(state.failed()+1);state.set_pipeline(model?"ready":"failed");state.set_index(model?"degraded":"failed");return app_error(r,e);}}
 Status IndexDocument(grpc::ServerContext* context,const rpc::IndexRequest* req,rpc::IndexResponse* r)override{ReconfigGuard guard(*this);try{guard.enter();std::shared_ptr<Model> current;std::string id,content,user,mime,image;int size=0,overlap=0;{std::lock_guard lock(mu);if(context->IsCancelled())throw std::runtime_error("Index operation cancelled");if(!model)throw std::runtime_error("Pipeline not initialized");if(req->document_id().empty())throw std::runtime_error("Document ID is empty");if(!req->image_bytes().empty()||req->mime_type().starts_with("image/"))throw std::runtime_error("Image embedding unavailable in text-only model");size=req->max_tokens_per_chunk()>0?req->max_tokens_per_chunk():480;overlap=req->chunk_overlap()<0?5:req->chunk_overlap();current=model;id=req->document_id();content=req->content();user=req->user_id();mime=req->mime_type();image=req->image_bytes();}
  auto prepared=prepare_chunks(*current,content,size,overlap,mime,context);
  std::lock_guard lock(mu);if(context->IsCancelled())throw std::runtime_error("Index operation cancelled");if(model!=current)throw std::runtime_error("Embedding model changed; retry");uint64_t rev=revision(id);Tx tx(*this);
  {Statement q(db,"INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?,?,?)");q.text(1,id);q.text(2,content);q.text(3,user);q.num(4,size);q.num(5,overlap);q.text(6,mime);if(image.empty())sqlite3_bind_null(q.p,7);else q.blob(7,image);q.row();}
  {Statement q(db,"INSERT OR REPLACE INTO linux.source_revisions VALUES(?,?,0)");q.text(1,id);q.num(2,rev);q.row();}
  {Statement q(db,"DELETE FROM vectors.chunks WHERE document_id=?");q.text(1,id);q.row();}
  crash("metadata_written");insert_vectors(prepared,id,rev,state.active_generation(),mime,context);crash("vectors_written");journal("replace",id,rev);crash("replace_before_commit");if(context->IsCancelled())throw std::runtime_error("Index operation cancelled");tx.commit();publish_index();crash("replace_after_commit");state.set_index("ready");changed();r->set_success(true);return Status::OK;
 }catch(const std::exception& e){std::lock_guard lock(mu);return app_error(r,e);}}
 Status DeleteDocument(grpc::ServerContext*,const rpc::DeleteRequest* req,rpc::DeleteResponse* r)override{ReconfigGuard guard(*this);guard.enter();std::lock_guard lock(mu);try{if(req->document_id().empty())throw std::runtime_error("Document ID is empty");Tx tx(*this);std::vector<std::string> ids{req->document_id()};if(req->document_id().starts_with("file://"))ids.push_back(req->document_id().substr(7));else ids.push_back("file://"+req->document_id());for(auto& id:ids){auto rev=revision(id);for(auto sqltext:{"DELETE FROM documents WHERE id=?","DELETE FROM vectors.chunks WHERE document_id=?"}){Statement q(db,sqltext);q.text(1,id);q.row();}Statement q(db,"INSERT OR REPLACE INTO linux.source_revisions VALUES(?,?,1)");q.text(1,id);q.num(2,rev);q.row();journal("delete",id,rev);}crash("delete_before_commit");tx.commit();publish_index();crash("delete_after_commit");changed();r->set_success(true);return Status::OK;}catch(const std::exception& e){return app_error(r,e);}}
 Status RetrieveContext(grpc::ServerContext*,const rpc::RetrieveRequest* req,rpc::RetrieveResponse* r)override {
  if(!req->has_query()||req->query().query_case()==rpc::Query::QUERY_NOT_SET)return {StatusCode::INVALID_ARGUMENT,"Query required"};
  if(req->max_results()<=0)return {StatusCode::INVALID_ARGUMENT,"max_results must be positive (Linux policy)"};
  // Only copy shared ownership under this short pointer lock. Writers build
  // replacements and retire old trees outside it, without blocking searches.
  std::shared_ptr<const SearchSnapshot> snapshot;
  {std::lock_guard lock(snapshot_mu);snapshot=search_snapshot;}
  if(!snapshot || !snapshot->model || !snapshot->model->available()){std::lock_guard lock(mu);return absent();}
  if(req->query().query_case()==rpc::Query::kAudioQuery)return {StatusCode::UNIMPLEMENTED,"Audio query unavailable in text-only model"};
  try {
    auto query=snapshot->model->embed(req->query().text_query(),EmbeddingTask::Query);
    std::set<std::string> allowed(req->allowed_document_ids().begin(),req->allowed_document_ids().end());
    for(auto match:snapshot->index.search(std::move(query),req->max_results(),static_cast<float>(req->min_similarity_score()),allowed)) {
      const auto &value=snapshot->index.chunks[match.chunk];auto *chunk=r->add_chunks();chunk->set_text(value.text);chunk->set_document_id(value.id);chunk->set_mime_type(value.mime);chunk->set_relevance_score(match.score);
    }
    return Status::OK;
  } catch(const std::exception &e){std::lock_guard lock(mu);note_adapter_failure(snapshot->model,e);return {StatusCode::INTERNAL,e.what()};}
 }
 Status Encode(grpc::ServerContext*,const rpc::EncodeRequest* req,rpc::EncodeResponse* r)override{std::shared_ptr<Model> current;{std::lock_guard lock(mu);if(!model)return {StatusCode::UNAVAILABLE,"Tokenizer not initialized"};current=model;}try{auto tokens=current->encode(req->text());std::lock_guard lock(mu);for(int t:tokens)r->add_tokens(t);return Status::OK;}catch(const std::exception& e){std::lock_guard lock(mu);note_adapter_failure(current,e);return {StatusCode::INTERNAL,e.what()};}}
 Status ChunkText(grpc::ServerContext*,const rpc::ChunkTextRequest* req,rpc::ChunkTextResponse* r)override{if(req->max_tokens_per_chunk()<=0)return {StatusCode::INVALID_ARGUMENT,"Chunk size must be positive (Linux policy)"};std::shared_ptr<Model> current;{std::lock_guard lock(mu);if(!model)return {StatusCode::UNAVAILABLE,"Tokenizer not initialized"};current=model;}try{auto parts=current->chunks(req->text(),req->max_tokens_per_chunk(),0);std::lock_guard lock(mu);for(auto& part:parts)r->add_chunks(part);return Status::OK;}catch(const std::exception& e){std::lock_guard lock(mu);note_adapter_failure(current,e);return {StatusCode::INTERNAL,e.what()};}}
 Status TruncateText(grpc::ServerContext*,const rpc::TruncateTextRequest* req,rpc::TruncateTextResponse* r)override{std::shared_ptr<Model> current;{std::lock_guard lock(mu);if(!model)return {StatusCode::UNAVAILABLE,"Tokenizer not initialized"};current=model;}try{auto tokens=current->encode(req->text());if(req->max_tokens()>0&&size_t(req->max_tokens())<tokens.size())tokens.resize(req->max_tokens());auto text=current->decode(tokens);std::lock_guard lock(mu);r->set_truncated_text(text);return Status::OK;}catch(const std::exception& e){std::lock_guard lock(mu);note_adapter_failure(current,e);return {StatusCode::INTERNAL,e.what()};}}
 Status ComputeEmbedding(grpc::ServerContext*,const rpc::ComputeEmbeddingRequest* req,rpc::ComputeEmbeddingResponse* r)override{std::shared_ptr<Model> current;{std::lock_guard lock(mu);if(!model||!model->available())return absent();current=model;}try{auto values=current->embed(req->text(), EmbeddingTask::Raw);std::lock_guard lock(mu);for(double x:values)r->add_embedding(x);return Status::OK;}catch(const std::exception& e){std::lock_guard lock(mu);note_adapter_failure(current,e);return {StatusCode::INTERNAL,e.what()};}}
 Status ComputeImageEmbedding(grpc::ServerContext*,const rpc::ComputeImageEmbeddingRequest* req,rpc::ComputeEmbeddingResponse*)override{std::lock_guard lock(mu);if(!model||!model->available())return absent();if(req->image_bytes().empty())return {StatusCode::INVALID_ARGUMENT,"Image bytes empty"};return {StatusCode::UNIMPLEMENTED,"Image embedding unavailable in text-only model"};}
 Status ComputeAudioEmbedding(grpc::ServerContext*,const rpc::ComputeAudioEmbeddingRequest* req,rpc::ComputeEmbeddingResponse*)override{std::lock_guard lock(mu);if(!model||!model->available())return absent();if(req->audio_bytes().empty())return {StatusCode::INVALID_ARGUMENT,"Audio bytes empty"};return {StatusCode::UNIMPLEMENTED,"Audio embedding unavailable in text-only model"};}
 Status GetState(grpc::ServerContext*,const ctl::Empty*,ctl::State* r)override{refresh_model_health();std::lock_guard lock(view_mu);*r=view;return Status::OK;}
 Status WatchState(grpc::ServerContext* context,const ctl::WatchRequest*,grpc::ServerWriter<ctl::State>* writer)override{uint64_t last=0;while(!context->IsCancelled()){refresh_model_health();ctl::State snapshot;{std::lock_guard lock(view_mu);snapshot=view;}if(snapshot.revision()!=last){if(!writer->Write(snapshot))break;last=snapshot.revision();}std::this_thread::sleep_for(std::chrono::milliseconds(100));}return Status::OK;}
};
int main(int argc,char** argv){signal(SIGPIPE,SIG_IGN);
int supervised=foresight::supervise_worker(argc,argv);if(supervised>=0)return supervised;
try{if(argc<3){std::cerr<<"Usage: ForesightHelper SOCKET STORAGE [--allow-test-models]\n";return 2;}std::string socket=argv[1],root=argv[2];bool test=argc>3&&std::string(argv[3])=="--allow-test-models";umask(0077);bool new_root=!fs::exists(root);if(new_root)fs::create_directories(root);struct stat root_info{};if(stat(root.c_str(),&root_info)||root_info.st_uid!=getuid()||(root_info.st_mode&0077))throw std::runtime_error("Storage requires a private user-owned directory");int lock=open((root+"/.helper.lock").c_str(),O_CREAT|O_RDWR|O_CLOEXEC,0600);if(lock<0||flock(lock,LOCK_EX|LOCK_NB))throw std::runtime_error("Another helper owns this storage root");fs::path parent=fs::path(socket).parent_path();if(parent.empty())throw std::runtime_error("Socket requires private parent directory");if(!fs::exists(parent))fs::create_directories(parent);struct stat info{};if(stat(parent.c_str(),&info)||info.st_uid!=getuid()||(info.st_mode&0077))throw std::runtime_error("Socket requires a private user-owned directory");if(fs::exists(socket)){auto ch=grpc::CreateChannel("unix:"+socket,grpc::InsecureChannelCredentials());if(ch->WaitForConnected(std::chrono::system_clock::now()+std::chrono::milliseconds(200)))throw std::runtime_error("Socket already serving");fs::remove(socket);}Service service(root,test);grpc::ServerBuilder b;b.AddListeningPort("unix:"+socket,grpc::InsecureServerCredentials());b.RegisterService(static_cast<rpc::RagService::Service*>(&service));b.RegisterService(static_cast<ctl::HelperControl::Service*>(&service));auto server=b.BuildAndStart();if(!server)throw std::runtime_error("Cannot listen on socket");chmod(socket.c_str(),0600);std::cout<<FORESIGHT_BUILD_ID<<" ready "<<socket<<std::endl;server->Wait();close(lock);return 0;}catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}}
