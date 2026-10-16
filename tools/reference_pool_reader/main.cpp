#include "pch.h"
#include "MachOHelper.h"
#include "DartLoader.h"
#include <vm/isolate.h>
#include <vm/thread.h>
#include <vm/dispatch_table.h>
#include <vm/class_table.h>
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
    std::printf("BOOL_NULL_OFFSETS TRUE[0x%lx] FALSE[0x%lx]\n",
      (unsigned long)(dart::UntaggedObject::ToAddr(dart::Bool::True().ptr()->untag()) - dart::UntaggedObject::ToAddr(dart::Object::null()->untag())),
      (unsigned long)(dart::UntaggedObject::ToAddr(dart::Bool::False().ptr()->untag()) - dart::UntaggedObject::ToAddr(dart::Object::null()->untag())));
    std::printf("POOL_LENGTH %ld\n",static_cast<long>(pool.Length()));
    for (intptr_t pp : {5033,26962,30858,30827,30828,30829,30830,30831,30832,30833,30834,30835,30836,30837,30838,30839,1168,6379,6381,530,12651,12652,12653,12654,12655,12656,12657,12658,12659,12660,12661,12662,12663,12664,12665,12666,12667,12668,12669,12670,12671,12672,12673,12674,12675,12676,12677,12678,12679,12680,12681,12682,12683,12684,12685,12686,12687,12688,12689,12690,12691,12692,12693,12694,12695,12696,12697,12698,12699,12700,12701,12702,12703,12704,12705,31008,30099,30359,30611,30612,30613,30614,30731,1211,531,30991,30715,30716,30723,30724,30123,30598,31052,30688,30689,26977,1109,7976,12640,12600,12601,12602,12603,12604,12605,12606,12607,12608,12609,12610,12611,12612,12613,12614,12621,12622,12625,12626,12627,12628,12629,12630,12631,12634,12635,12636,12637,12638,12639,12641,12642,12643,12644,12645,4632,26969,4563,31045,9969,66,16,4659,10206,31046,31047,31049,4777,4924,4920,5265,8324,9779,3012,5279,10495,9018,8511,9018,9245,23909,23910,23911,23918,23926,23929,26597,26598,26599,26600,26601,26602,26604,26605,26606,2765,21048,9836,9089,4620,9663,82,20693,5845,26972,5940,3656,492,4518,4523,27,566,635,855,11631,22356,13118,11291,24954,24977,24980,24985,24986,26550,25030,25006,25007,4265,23921,11620,21079,26976,26978,26981,26989,26990,26995,26996,27001,27002,27003,27004,27424}) {
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

      if (pp == 30858 && obj.IsInstance()) {
        const auto& instance = dart::Instance::Cast(obj);
        const auto& cls = dart::Class::Handle(zone, instance.clazz());
        for (intptr_t offset=8; offset<cls.host_instance_size(); offset+=8) {
          dart::ObjectPtr value;
          std::memcpy(&value, reinterpret_cast<void*>(dart::UntaggedObject::ToAddr(obj.ptr()->untag()) + offset), sizeof(value));
          if (value == dart::Object::null()) std::printf("CONFIG_SLOT[%ld] NULL\n", (long)offset);
          else if (value == dart::Bool::True().ptr()) std::printf("CONFIG_SLOT[%ld] TRUE\n", (long)offset);
          else if (value == dart::Bool::False().ptr()) std::printf("CONFIG_SLOT[%ld] FALSE\n", (long)offset);
          else if (!value.IsHeapObject())
            std::printf("CONFIG_SLOT[%ld] SMI_OR_RAW[%ld]\n", (long)offset, (long)dart::Smi::Value(dart::Smi::RawCast(value)));
          else std::printf("CONFIG_SLOT[%ld] OBJECT_REF\n", (long)offset);
        }
        const auto& fields = dart::Array::Handle(zone, cls.fields());
        for (intptr_t j=0; j<fields.Length(); j++) {
          const auto& field = dart::Field::Handle(zone, dart::Field::RawCast(fields.At(j)));
          if (!field.is_static()) {
            const auto& value = dart::Object::Handle(zone, instance.GetField(field));
            std::printf("CONFIG_FIELD OFFSET[%ld] %s VALUE[%s]\n", (long)field.HostOffset(), field.ToCString(), value.ToCString());
          }
        }
      }
      if (obj.IsFunction()) {
        const auto& function = dart::Function::Cast(obj);
        std::printf("FUNCTION_PP[%ld] CODE_OFFSET[0x%lx]\n", (long)pp,
          (unsigned long)(function.entry_point() - reinterpret_cast<dart::uword>(image.lib)));
      }
      if (obj.IsString() && ((pp >= 12600 && pp <= 12705) || (pp >= 30827 && pp <= 30839) || pp == 11631 || pp == 1168 || pp == 6379 || pp == 6381 || pp == 530 || pp == 31045 || pp == 31046 || (pp >= 30611 && pp <= 30614) || pp == 31008 || pp == 30099 || pp == 30359 || pp == 30731 || pp == 1211 || pp == 531 || pp == 30991 || pp == 1109 || pp == 3656 || pp == 4265 || pp == 23921 || pp == 25006 || pp == 25007 || pp == 24980)) {
        const auto& str = dart::String::Cast(obj);
        std::printf("STRING_UNITS[%ld]",(long)pp);
        for (intptr_t j=0;j<str.Length();j++) std::printf(" %04x",str.CharAt(j));
        std::printf("\n");
      }
      if (pp == 11620 && obj.IsInstance()) {
        const auto raw = dart::UntaggedObject::ToAddr(obj.ptr()->untag());
        int64_t stored; std::memcpy(&stored,reinterpret_cast<void*>(raw+8),sizeof(stored));
        const auto bitmap = isolate->group()->class_table()->GetUnboxedFieldsMapAt(obj.GetClassId());
        std::printf("TIMEOUT_FIELD[0x8] RAW[%lld] UNBOXED[%d]\n",(long long)stored,bitmap.Get(1));
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
    std::printf("LIBC_CEIL_THREAD_OFFSET[%ld]\n", (long)dart::Thread::LibcCeil_entry_point_offset());
    std::printf("LIBC_ROUND_THREAD_OFFSET[%ld]\n", (long)dart::Thread::LibcRound_entry_point_offset());
    const auto origin = isolate->group()->dispatch_table()->ArrayOrigin();
    std::printf("LIST_EMPTY_DISPATCH CODE_OFFSET[0x%lx]\n",
      (unsigned long)(origin[dart::kGrowableObjectArrayCid + 42110] - reinterpret_cast<dart::uword>(image.lib)));

    // Resolve only the public encryption-service methods called by AssetManager.
    // Do not inspect key objects or keychain contents.
    const auto class_table = isolate->group()->class_table();
    for (intptr_t cid=0; cid<class_table->NumCids(); cid++) {
      if (!class_table->HasValidClassAt(cid)) continue;
      const auto& cls = dart::Class::Handle(zone, class_table->At(cid));
      const auto& name = dart::String::Handle(zone, cls.Name());
      if (std::strcmp(name.ToCString(), "MacosEncryptionService") != 0) continue;
      std::printf("ENCRYPTION_CLASS CID[%ld] NAME[%s]\n", (long)cid, name.ToCString());
      for (intptr_t offset : {-4096,-4092,-4085}) {
        const auto entry = origin[cid + offset];
        std::printf("ENCRYPTION_DISPATCH[%ld] CODE_OFFSET[0x%lx]\n",
          (long)offset,(unsigned long)(entry - reinterpret_cast<dart::uword>(image.lib)));
      }
    }
    for (intptr_t offset : {-4092,-4090,-4096,23776}) {
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
