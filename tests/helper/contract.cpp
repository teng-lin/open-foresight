#include "research/xeno/labs/foresight/launch_agent/proto/rag_service.grpc.pb.h"
#include "helper_control.grpc.pb.h"
#include <grpcpp/grpcpp.h>
#include <sqlite3.h>
#include <filesystem>
#include <iostream>
#include <fstream>
#include <thread>
#include <future>
#include <type_traits>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>
namespace p=research::xeno::labs::foresight::launch_agent::proto;
namespace c=foresight::linux::control::v1;
#define REQUIRE(x) do{if(!(x))throw std::runtime_error(std::string(__FILE__)+":"+std::to_string(__LINE__)+": "+#x);}while(0)
template<class Q,class R,class F> grpc::Status call(Q& q,R& r,F f){grpc::ClientContext ctx;ctx.set_deadline(std::chrono::system_clock::now()+std::chrono::seconds(5));auto status=f(&ctx,q,&r);if constexpr(std::is_same_v<R,p::UpdateModelPathsResponse>){if(!status.ok()||!r.success())std::cerr<<"Configure error: grpc="<<status.error_code()<<" message="<<status.error_message()<<" application="<<r.error_message()<<"\n";}return status;}
int main(int argc,char** argv){setenv("FORESIGHT_TEST_DELAY_MS","2",1);std::string dir=(std::filesystem::temp_directory_path().string()+"/foresight-contract-")+std::to_string(getpid());std::filesystem::create_directories(dir);chmod(dir.c_str(),0700);std::string socket=dir+"/run/helper.sock";pid_t pid=-1;try{auto start=[&]{pid=fork();if(pid==0){execl(argv[1],argv[1],socket.c_str(),dir.c_str(),"--allow-test-models",(char*)nullptr);_exit(127);}auto channel=grpc::CreateChannel("unix:"+socket,grpc::InsecureChannelCredentials());REQUIRE(channel->WaitForConnected(std::chrono::system_clock::now()+std::chrono::seconds(10)));return p::RagService::NewStub(channel);};auto stub=start();p::PingRequest ping;p::PingResponse pong;REQUIRE(call(ping,pong,[&](auto* ctx,auto& q,auto* r){return stub->Ping(ctx,q,r);}).ok());REQUIRE(pong.success()&&pong.version()=="1.0.3");p::ComputeImageEmbeddingRequest img;p::ComputeEmbeddingResponse vec;REQUIRE(call(img,vec,[&](auto* ctx,auto& q,auto* r){return stub->ComputeImageEmbedding(ctx,q,r);}).error_code()==grpc::StatusCode::UNAVAILABLE);
 p::UpdateModelPathsRequest model;model.set_embedding_model_path("test://deterministic");p::UpdateModelPathsResponse configured;REQUIRE(call(model,configured,[&](auto* ctx,auto& q,auto* r){return stub->UpdateModelPaths(ctx,q,r);}).ok()&&configured.success());
 auto active_generation=[&]{auto status=c::HelperControl::NewStub(grpc::CreateChannel("unix:"+socket,grpc::InsecureChannelCredentials()));c::Empty q;c::State r;REQUIRE(call(q,r,[&](auto* ctx,auto& x,auto* y){return status->GetState(ctx,x,y);}).ok());return r.active_generation();};
 auto first_generation=active_generation();
 REQUIRE(call(model,configured,[&](auto* ctx,auto& q,auto* r){return stub->UpdateModelPaths(ctx,q,r);}).ok()&&configured.success());
 REQUIRE(active_generation()==first_generation);
 REQUIRE(call(img,vec,[&](auto* ctx,auto& q,auto* r){return stub->ComputeImageEmbedding(ctx,q,r);}).error_code()==grpc::StatusCode::INVALID_ARGUMENT);img.set_image_bytes("image");REQUIRE(call(img,vec,[&](auto* ctx,auto& q,auto* r){return stub->ComputeImageEmbedding(ctx,q,r);}).error_code()==grpc::StatusCode::UNIMPLEMENTED);

 p::ComputeEmbeddingRequest er;er.set_text("cats");p::ComputeEmbeddingResponse ev;REQUIRE(call(er,ev,[&](auto* ctx,auto& q,auto* r){return stub->ComputeEmbedding(ctx,q,r);}).ok()&&ev.embedding_size()==64);
 p::EncodeRequest eq;eq.set_text("abc");p::EncodeResponse et;REQUIRE(call(eq,et,[&](auto* ctx,auto& q,auto* r){return stub->Encode(ctx,q,r);}).ok()&&et.tokens_size()==3&&et.tokens(0)==97);
 p::ChunkTextRequest cq;cq.set_text("abcdef");cq.set_max_tokens_per_chunk(2);p::ChunkTextResponse cr;REQUIRE(call(cq,cr,[&](auto* ctx,auto& q,auto* r){return stub->ChunkText(ctx,q,r);}).ok()&&cr.chunks_size()==3&&cr.chunks(1)=="cd");cq.set_max_tokens_per_chunk(0);REQUIRE(call(cq,cr,[&](auto* ctx,auto& q,auto* r){return stub->ChunkText(ctx,q,r);}).error_code()==grpc::StatusCode::INVALID_ARGUMENT);
 p::ComputeAudioEmbeddingRequest aq;REQUIRE(call(aq,vec,[&](auto* ctx,auto& q,auto* r){return stub->ComputeAudioEmbedding(ctx,q,r);}).error_code()==grpc::StatusCode::INVALID_ARGUMENT);aq.set_audio_bytes("wav");REQUIRE(call(aq,vec,[&](auto* ctx,auto& q,auto* r){return stub->ComputeAudioEmbedding(ctx,q,r);}).error_code()==grpc::StatusCode::UNIMPLEMENTED);
 p::RetrieveRequest missing;p::RetrieveResponse no_context;REQUIRE(call(missing,no_context,[&](auto* ctx,auto& q,auto* r){return stub->RetrieveContext(ctx,q,r);}).error_code()==grpc::StatusCode::INVALID_ARGUMENT);
 auto index=[&](const char* id,const char* text){p::IndexRequest q;q.set_document_id(id);q.set_content(text);q.set_user_id("local_user");q.set_max_tokens_per_chunk(-1);q.set_chunk_overlap(-1);p::IndexResponse r;REQUIRE(call(q,r,[&](auto* ctx,auto& x,auto* y){return stub->IndexDocument(ctx,x,y);}).ok()&&r.success());};index("cats","cats purr softly");index("dogs","dogs bark loudly");

 // Static reference 0x100355200 advances exactly size tokens; overlap applies only to the byte-fallback path.
 auto tokenizer_windows=[&](int size,int overlap,const std::vector<std::string>& expected){
  p::IndexRequest q;q.set_document_id("tokenizer-windows");q.set_content("abcdef");q.set_max_tokens_per_chunk(size);q.set_chunk_overlap(overlap);p::IndexResponse r;REQUIRE(call(q,r,[&](auto* ctx,auto& x,auto* y){return stub->IndexDocument(ctx,x,y);}).ok()&&r.success());
  sqlite3* vectors=nullptr;REQUIRE(sqlite3_open((dir+"/rag_vector.db").c_str(),&vectors)==SQLITE_OK);sqlite3_stmt* rows=nullptr;REQUIRE(sqlite3_prepare_v2(vectors,"SELECT text FROM chunks WHERE document_id='tokenizer-windows' ORDER BY ordinal",-1,&rows,nullptr)==SQLITE_OK);std::vector<std::string> actual;while(sqlite3_step(rows)==SQLITE_ROW)actual.push_back((const char*)sqlite3_column_text(rows,0));sqlite3_finalize(rows);sqlite3_close(vectors);REQUIRE(actual==expected);
  sqlite3* meta=nullptr;REQUIRE(sqlite3_open((dir+"/agent_metadata.db").c_str(),&meta)==SQLITE_OK);REQUIRE(sqlite3_prepare_v2(meta,"SELECT maxTokensPerChunk,chunkOverlap FROM documents WHERE id='tokenizer-windows'",-1,&rows,nullptr)==SQLITE_OK);REQUIRE(sqlite3_step(rows)==SQLITE_ROW);REQUIRE(sqlite3_column_int(rows,0)==size&&sqlite3_column_int(rows,1)==(overlap<0?5:overlap));sqlite3_finalize(rows);sqlite3_close(meta);
 };
 tokenizer_windows(2,1,{"ab","cd","ef"});tokenizer_windows(1,-1,{"a","b","c","d","e","f"});tokenizer_windows(2,999,{"ab","cd","ef"});
 index("threshold","threshold");
 p::RetrieveRequest boundary;boundary.mutable_query()->set_text_query("threshold");boundary.set_max_results(1);boundary.add_allowed_document_ids("threshold");boundary.set_min_similarity_score(1.0+1e-8);p::RetrieveResponse boundary_result;REQUIRE(call(boundary,boundary_result,[&](auto* ctx,auto& q,auto* r){return stub->RetrieveContext(ctx,q,r);}).ok()&&boundary_result.chunks_size()==1);
 boundary.set_min_similarity_score(1.0+1e-6);boundary_result.Clear();REQUIRE(call(boundary,boundary_result,[&](auto* ctx,auto& q,auto* r){return stub->RetrieveContext(ctx,q,r);}).ok()&&boundary_result.chunks_size()==0);
 auto retrieve=[&](const char* query,const char* filter=""){p::RetrieveRequest q;q.mutable_query()->set_text_query(query);q.set_max_results(10);q.set_min_similarity_score(0.01);if(*filter)q.add_allowed_document_ids(filter);p::RetrieveResponse r;REQUIRE(call(q,r,[&](auto* ctx,auto& x,auto* y){return stub->RetrieveContext(ctx,x,y);}).ok());return r;};auto found=retrieve("cats");REQUIRE(found.chunks_size()&&found.chunks(0).document_id()=="cats");REQUIRE(retrieve("cats","dogs").chunks_size()==0);
 // Keep a replacement transaction open while a reader searches its previous
 // immutable index. A global read/write mutex would deadlock this assertion.
 std::ofstream(dir+"/.pause-at")<<"partial_vectors";
 auto publishing=std::async(std::launch::async,[&]{index("new","cats new document");});
 for(int i=0;i<100&&!std::filesystem::exists(dir+"/.paused");++i)std::this_thread::sleep_for(std::chrono::milliseconds(20));
 REQUIRE(std::filesystem::exists(dir+"/.paused"));
 auto reading=std::chrono::steady_clock::now();auto during=retrieve("cats");
 REQUIRE(std::chrono::steady_clock::now()-reading<std::chrono::milliseconds(500));
 REQUIRE(during.chunks_size()&&during.chunks(0).document_id()=="cats");
 std::filesystem::remove(dir+"/.pause-at");publishing.get();
 {sqlite3* vectors=nullptr;REQUIRE(sqlite3_open((dir+"/rag_vector.db").c_str(),&vectors)==SQLITE_OK);sqlite3_stmt* row=nullptr;REQUIRE(sqlite3_prepare_v2(vectors,"SELECT typeof(embedding),substr(embedding,1,4) FROM chunks LIMIT 1",-1,&row,nullptr)==SQLITE_OK);REQUIRE(sqlite3_step(row)==SQLITE_ROW);REQUIRE(std::string((const char*)sqlite3_column_text(row,0))=="blob");REQUIRE(std::string((const char*)sqlite3_column_blob(row,1),4)=="FSV1");sqlite3_finalize(row);sqlite3_close(vectors);}
 index("cats","birds sing");REQUIRE(retrieve("cats","cats").chunks_size()==0);REQUIRE(retrieve("birds","cats").chunks_size()==1);
 p::TruncateTextRequest tr;tr.set_text("abcdef");tr.set_max_tokens(3);p::TruncateTextResponse ts;REQUIRE(call(tr,ts,[&](auto* ctx,auto& q,auto* r){return stub->TruncateText(ctx,q,r);}).ok()&&ts.truncated_text()=="abc");tr.set_max_tokens(0);REQUIRE(call(tr,ts,[&](auto* ctx,auto& q,auto* r){return stub->TruncateText(ctx,q,r);}).ok()&&ts.truncated_text()=="abcdef");
 auto before_restart=active_generation();kill(pid,SIGKILL);waitpid(pid,nullptr,0);pid=-1;stub=start();REQUIRE(call(model,configured,[&](auto* ctx,auto& q,auto* r){return stub->UpdateModelPaths(ctx,q,r);}).ok()&&configured.success());REQUIRE(active_generation()==before_restart);REQUIRE(retrieve("birds","cats").chunks_size()==1);p::DeleteRequest del;del.set_document_id("cats");p::DeleteResponse deleted;REQUIRE(call(del,deleted,[&](auto* ctx,auto& q,auto* r){return stub->DeleteDocument(ctx,q,r);}).ok()&&deleted.success());REQUIRE(retrieve("birds","cats").chunks_size()==0);

 // Inject process death at every publication boundary; attached SQLite rollback must preserve the old revision.
 index("stable","original persistent source");
 for(const char* step:{"metadata_written","partial_vectors","vectors_written","replace_before_commit","replace_after_commit","delete_before_commit","delete_after_commit","model_before_commit"}){
  {std::ofstream f(dir+"/.crash-at");f<<step;}
  bool deletion=std::string(step).starts_with("delete");bool replacement_model=std::string(step)=="model_before_commit";
  if(deletion){p::DeleteRequest q;q.set_document_id("stable");p::DeleteResponse r;REQUIRE(!call(q,r,[&](auto* ctx,auto& x,auto* y){return stub->DeleteDocument(ctx,x,y);}).ok());}
  else if(replacement_model){p::UpdateModelPathsRequest force=model;force.set_cache_dir("force-crash-rebuild");kill(pid,SIGTERM);waitpid(pid,nullptr,0);pid=-1;stub=start();REQUIRE(!call(force,configured,[&](auto* ctx,auto& x,auto* y){return stub->UpdateModelPaths(ctx,x,y);}).ok());}
  else {p::IndexRequest q;q.set_document_id("stable");q.set_content("replacement revised source");q.set_max_tokens_per_chunk(480);p::IndexResponse r;REQUIRE(!call(q,r,[&](auto* ctx,auto& x,auto* y){return stub->IndexDocument(ctx,x,y);}).ok());}
  int result;waitpid(pid,&result,0);pid=-1;REQUIRE(WIFEXITED(result)&&WEXITSTATUS(result)==86);std::filesystem::remove(dir+"/.crash-at");stub=start();
  REQUIRE(call(model,configured,[&](auto* ctx,auto& x,auto* y){return stub->UpdateModelPaths(ctx,x,y);}).ok()&&configured.success());
  if(std::string(step)=="replace_after_commit")REQUIRE(retrieve("replacement","stable").chunks_size()>0);
  else if(std::string(step)=="delete_after_commit")REQUIRE(retrieve("original","stable").chunks_size()==0);
  else REQUIRE(retrieve("original","stable").chunks_size()>0);
  index("stable","original persistent source");
 }

 sqlite3* metadata=nullptr;REQUIRE(sqlite3_open((dir+"/agent_metadata.db").c_str(),&metadata)==SQLITE_OK);sqlite3_stmt* tables=nullptr;REQUIRE(sqlite3_prepare_v2(metadata,"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",-1,&tables,nullptr)==SQLITE_OK);std::vector<std::string> names;while(sqlite3_step(tables)==SQLITE_ROW)names.push_back((const char*)sqlite3_column_text(tables,0));sqlite3_finalize(tables);sqlite3_close(metadata);REQUIRE(names==std::vector<std::string>({"documents","settings"}));REQUIRE(std::filesystem::exists(dir+"/linux_state.db"));
 auto control=c::HelperControl::NewStub(grpc::CreateChannel("unix:"+socket,grpc::InsecureChannelCredentials()));c::Empty empty;c::State state;REQUIRE(call(empty,state,[&](auto* ctx,auto& q,auto* r){return control->GetState(ctx,q,r);}).ok());REQUIRE(state.pipeline()=="ready"&&state.model().dimensions()==64&&state.model().modalities_size()==1);


 grpc::ClientContext watch_context;watch_context.set_deadline(std::chrono::system_clock::now()+std::chrono::seconds(5));c::WatchRequest watch;watch.set_last_revision(state.revision());auto stream=control->WatchState(&watch_context,watch);c::State initial;REQUIRE(stream->Read(&initial)&&initial.instance_id()==state.instance_id());watch_context.TryCancel();REQUIRE(stream->Finish().error_code()==grpc::StatusCode::CANCELLED);
 // Mutations submitted while a replacement is building must apply after activation, never resurrect deletions.
 for(int n=0;n<30;++n)index(("rebuild-"+std::to_string(n)).c_str(),"persistent rebuilding corpus");
 p::UpdateModelPathsRequest rebuild;rebuild.set_cache_dir("test-rebuild");p::UpdateModelPathsResponse rebuilt;
 std::thread rebuilding([&]{REQUIRE(call(rebuild,rebuilt,[&](auto* ctx,auto& q,auto* r){return stub->UpdateModelPaths(ctx,q,r);}).ok()&&rebuilt.success());});
 bool observed=false;
 for(int n=0;n<100;++n){c::State snap;REQUIRE(call(empty,snap,[&](auto* ctx,auto& q,auto* r){return control->GetState(ctx,q,r);}).ok());if(snap.index()=="building"){observed=true;break;}std::this_thread::sleep_for(std::chrono::milliseconds(1));}
 REQUIRE(observed);
 std::thread updating([&]{index("during-rebuild","concurrent replacement survives");});
 std::thread deleting([&]{p::DeleteRequest q;q.set_document_id("rebuild-0");p::DeleteResponse r;REQUIRE(call(q,r,[&](auto* ctx,auto& x,auto* y){return stub->DeleteDocument(ctx,x,y);}).ok()&&r.success());});
 rebuilding.join();updating.join();deleting.join();REQUIRE(retrieve("concurrent","during-rebuild").chunks_size()==1);REQUIRE(retrieve("persistent","rebuild-0").chunks_size()==0);
 // A timed-out insertion rolls back and releases the model before the next request.
 {
  p::IndexRequest q;q.set_document_id("cancelled-source");q.set_content(std::string(8000,'x'));
  q.set_max_tokens_per_chunk(8);p::IndexResponse r;grpc::ClientContext ctx;
  ctx.set_deadline(std::chrono::system_clock::now()+std::chrono::milliseconds(30));
  REQUIRE(stub->IndexDocument(&ctx,q,&r).error_code()==grpc::StatusCode::DEADLINE_EXCEEDED);
  REQUIRE(retrieve("x","cancelled-source").chunks_size()==0);
 }
 auto preserved_generation=active_generation();
 {
  p::UpdateModelPathsRequest q;q.set_cache_dir("cancelled-rebuild");
  p::UpdateModelPathsResponse r;grpc::ClientContext ctx;
  ctx.set_deadline(std::chrono::system_clock::now()+std::chrono::milliseconds(15));
  REQUIRE(stub->UpdateModelPaths(&ctx,q,&r).error_code()==grpc::StatusCode::DEADLINE_EXCEEDED);
  REQUIRE(retrieve("concurrent","during-rebuild").chunks_size()==1);
  REQUIRE(active_generation()==preserved_generation);
 }
 // Old or incompatible cache identities rebuild once instead of reusing stale vectors.
 kill(pid,SIGTERM);waitpid(pid,nullptr,0);pid=-1;
 sqlite3* cache_db=nullptr;REQUIRE(sqlite3_open((dir+"/agent_metadata.db").c_str(),&cache_db)==SQLITE_OK);
 REQUIRE(sqlite3_exec(cache_db,"UPDATE settings SET value='obsolete' WHERE key='index_model_identity'",nullptr,nullptr,nullptr)==SQLITE_OK);
 sqlite3_close(cache_db);stub=start();
 REQUIRE(call(model,configured,[&](auto* ctx,auto& q,auto* r){return stub->UpdateModelPaths(ctx,q,r);}).ok()&&configured.success());
 REQUIRE(active_generation()>preserved_generation);
 REQUIRE(retrieve("concurrent","during-rebuild").chunks_size()==1);
 kill(pid,SIGTERM);waitpid(pid,nullptr,0);pid=-1;std::filesystem::remove_all(dir);std::cout<<"helper contracts passed\n";return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<"\n";if(pid>0){kill(pid,SIGKILL);waitpid(pid,nullptr,0);}std::filesystem::remove_all(dir);return 1;}}
