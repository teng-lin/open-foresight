#include "vector_index.h"
#include <cassert>
#include <random>
#include <iostream>
int main() {
  using namespace foresight;
  std::mt19937 rng(71);std::normal_distribution<double> random;
  std::vector<IndexedChunk> chunks;
  for(int i=0;i<300;++i){std::vector<double> vector;for(int j=0;j<12;++j)vector.push_back(random(rng));assert(read_vector(vector_blob(vector))==vector);chunks.push_back({std::to_string(i),std::to_string(i%7),"text/plain",vector});}
  VectorIndex index(chunks);
  for(int test=0;test<80;++test){std::vector<double> query;for(int j=0;j<12;++j)query.push_back(random(rng));
    auto actual=index.search(query,5,-.2,{"1","4"});
    double norm=0;for(double x:query)norm+=x*x;for(double &x:query)x/=sqrt(norm);
    std::vector<VectorIndex::Match> expected;
    for(size_t i=0;i<index.chunks.size();++i){auto &chunk=index.chunks[i];if(chunk.id!="1"&&chunk.id!="4")continue;double score=0;for(int j=0;j<12;++j)score+=query[j]*chunk.vector[j];if(score>=-.2)expected.push_back({score,i});}
    std::sort(expected.begin(),expected.end(),[](auto a,auto b){return a.score!=b.score?a.score>b.score:a.chunk<b.chunk;});expected.resize(std::min(size_t(5),expected.size()));
    assert(actual.size()==expected.size());for(size_t i=0;i<actual.size();++i)assert(actual[i].chunk==expected[i].chunk);
  }
  bool rejected=false;try{read_vector("FSV1x");}catch(...){rejected=true;}assert(rejected);
  VectorIndex zero({{"zero","0","",{0,0}}, {"unit","1","",{1,0}}});
  assert(zero.search({0,0},2,0).size()==2);
  VectorIndex mixed({{"first","0","",{1,0}}, {"zero","1","",{0,0}}, {"orthogonal","2","",{0,1}}});
  assert(mixed.search({0,0},1,0).front().chunk==0);
  auto ties=mixed.search({0,1},2,0);assert(ties.size()==2 && ties[0].chunk==2 && ties[1].chunk==0);
  std::cout<<"binary serialization and exact indexed filtered top-k passed\n";
}
