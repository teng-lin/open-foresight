#pragma once
#include <cctype>
#include <string_view>

namespace foresight {
// Validate a complete JSON string before embedding a worker frame into an
// event. This leaves decoding/Unicode escapes to the client's JSON parser.
inline bool json_string_literal(std::string_view value) {
  if (value.size()<2 || value.front()!='"') return false;
  for(size_t i=1;i<value.size();++i) {
    const auto c=static_cast<unsigned char>(value[i]);
    if(c=='"')return i+1==value.size();
    if(c<0x20)return false;
    if(c=='\\') {
      if(++i>=value.size())return false;
      const char escape=value[i];
      if(escape=='u') {
        for(int j=0;j<4;++j)if(++i>=value.size() || !std::isxdigit(static_cast<unsigned char>(value[i])))return false;
      } else if(std::string_view("\"\\/bfnrt").find(escape)==std::string_view::npos)return false;
    } else if(c>=0x80) {
      int count=c>=0xf0&&c<=0xf4?3:c>=0xe0&&c<=0xef?2:c>=0xc2&&c<=0xdf?1:-1;
      if(count<0 || i+count>=value.size())return false;
      unsigned code=c&((1u<<(6-count))-1);
      for(int j=0;j<count;++j){auto part=static_cast<unsigned char>(value[++i]);if((part&0xc0)!=0x80)return false;code=(code<<6)|(part&0x3f);}
      if(code>0x10ffff || (code>=0xd800&&code<=0xdfff) || (count==1&&code<0x80) || (count==2&&code<0x800) || (count==3&&code<0x10000))return false;
    }
  }
  return false;
}
}
