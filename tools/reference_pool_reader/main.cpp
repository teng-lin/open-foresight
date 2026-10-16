#include "pch.h"
#include "MachOHelper.h"
#include "DartLoader.h"
#include <vm/isolate.h>
#include <vm/thread.h>
#include <vm/dispatch_table.h>
#include <vm/heap/safepoint.h>
#include <cstdio>
int main(int argc, char** argv) {
  setvbuf(stdout,nullptr,_IONBF,0);
  if (argc != 2) return 2;
  try {
    auto image = MachOHelper::MapLibApp(argv[1]);
    auto isolate = reinterpret_cast<dart::Isolate*>(DartLoader::Load(image));
    Dart_EnterScope();
    isolate->safepoint_handler()->ExitSafepointUsingLock(dart::Thread::Current());
    auto zone = dart::Thread::Current()->zone();
    auto& pool = *reinterpret_cast<dart::ObjectPool*>(dart::VMHandles::AllocateHandle(zone));
    pool = isolate->group()->object_store()->global_object_pool();
    std::printf("POOL_LENGTH %ld\n",static_cast<long>(pool.Length()));
    for (intptr_t pp : {27,566,635,855,11631,22356,13118,11291,24954,24977,24980,24985,24986,26550,25030,25006,25007,4265,23921}) {
      const auto offset = pp * 8;
      const auto index = dart::ObjectPool::IndexFromOffset(offset - dart::kHeapObjectTag);
      if (pool.TypeAt(index) == dart::ObjectPool::EntryType::kImmediate) {
        auto bits = pool.RawValueAt(index);
        double value; std::memcpy(&value,&bits,sizeof(value));
        std::printf("PP[%ld] OFFSET[0x%lx] INDEX[%ld] IMMEDIATE[0x%lx] DOUBLE[%.17g]\n",
          (long)pp,(unsigned long)offset,(long)index,(unsigned long)bits,value);
        continue;
      }
      auto& obj = dart::Object::Handle(zone, pool.ObjectAt(index));
      std::printf("PP[%ld] OFFSET[0x%lx] INDEX[%ld] CID[%ld] %s\n",
        static_cast<long>(pp),static_cast<unsigned long>(offset),
        static_cast<long>(index),static_cast<long>(obj.GetClassId()),obj.ToCString());
      if (obj.IsString() && (pp == 4265 || pp == 23921 || pp == 25006 || pp == 25007 || pp == 24980)) {
        const auto& str = dart::String::Cast(obj);
        std::printf("STRING_UNITS[%ld]",(long)pp);
        for (intptr_t j=0;j<str.Length();j++) std::printf(" %04x",str.CharAt(j));
        std::printf("\n");
      }
      if (pp == 25030 && obj.IsInstance()) {
        // Layout bound by ProtobufEnum.toString at 0x100b51e00.
        const auto tagged = dart::UntaggedObject::ToAddr(obj.ptr()->untag()) + dart::kHeapObjectTag;
        int64_t value; dart::ObjectPtr namePtr;
        std::memcpy(&value,reinterpret_cast<void*>(tagged+7),sizeof(value));
        std::memcpy(&namePtr,reinterpret_cast<void*>(tagged+15),sizeof(namePtr));
        auto& name = dart::Object::Handle(zone,namePtr);
        std::printf("MODEL_ENUM_VALUE[%lld] NAME[%s]\n",(long long)value,name.ToCString());
      }
      if (obj.IsArray()) {
        const auto& array = dart::Array::Cast(obj);
        for (intptr_t j=0; j<array.Length(); j++) {
          auto& element = dart::Object::Handle(zone,array.At(j));
          std::printf("ARRAY[%ld][%ld] %s\n",(long)pp,(long)j,element.ToCString());
        }
      }
    }
    const auto origin = isolate->group()->dispatch_table()->ArrayOrigin();
    for (intptr_t offset : {-4092,-4090,-4096}) {
      auto entry = origin[95 + offset];
      std::printf("STRING_DISPATCH[%ld] CODE_OFFSET[0x%lx]\n",
        (long)offset,(unsigned long)(entry - reinterpret_cast<dart::uword>(image.lib)));
    }
    for (intptr_t cid : {dart::kOneByteStringCid, dart::kTwoByteStringCid}) {
      auto entry = origin[cid + 10470];
      std::printf("STRING_HASH_CID[%ld] CODE_OFFSET[0x%lx]\n",
        (long)cid,(unsigned long)(entry - reinterpret_cast<dart::uword>(image.lib)));
    }
    for (intptr_t offset : {-4010}) {
      auto entry = origin[dart::kSmiCid + offset];
      std::printf("SMI_DISPATCH[%ld] CODE_OFFSET[0x%lx]\n",
        (long)offset,(unsigned long)(entry - reinterpret_cast<dart::uword>(image.lib)));
    }
    Dart_ExitScope();
    DartLoader::Unload();
  } catch (const std::exception& e) {
    std::fprintf(stderr,"Reader error: %s\n",e.what());
    return 1;
  }
  return 0;
}
