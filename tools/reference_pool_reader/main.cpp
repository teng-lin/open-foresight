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
    // These two public enum candidates expose only their own value/name.
    // A non-enum (for example a values map) is deliberately not traversed.
    for (intptr_t pp : {13169,17020}) {
      const auto index = dart::ObjectPool::IndexFromOffset(pp * 8 - dart::kHeapObjectTag);
      if (index < 0 || index >= pool.Length() ||
          pool.TypeAt(index) == dart::ObjectPool::EntryType::kImmediate) continue;
      const auto& value = dart::Object::Handle(zone, pool.ObjectAt(index));
      std::printf("PUBLIC_DOWNLOAD_ENUM_PP[%ld] CID[%ld]\n", (long)pp, (long)value.GetClassId());
      if (!value.IsInstance()) continue;
      const auto& cls = dart::Class::Handle(zone, dart::Instance::Cast(value).clazz());
      const auto& name = dart::String::Handle(zone, cls.Name());
      if (std::strstr(name.ToCString(), "FallbackMode") == nullptr ||
          cls.host_instance_size() < 24) continue;
      std::printf("PUBLIC_DOWNLOAD_ENUM_PP[%ld] CLASS[%s]\n", (long)pp, name.ToCString());
      const auto bitmap = isolate->group()->class_table()->GetUnboxedFieldsMapAt(value.GetClassId());
      for (intptr_t offset : {8,16}) {
        const auto address = dart::UntaggedObject::ToAddr(value.ptr()->untag()) + offset;
        if (bitmap.Get(offset / 8)) {
          int64_t number;
          std::memcpy(&number, reinterpret_cast<void*>(address), sizeof(number));
          std::printf("PUBLIC_DOWNLOAD_ENUM_PP[%ld] OFFSET[%ld] VALUE[%lld]\n", (long)pp, (long)offset, (long long)number);
        } else {
          dart::ObjectPtr pointer;
          std::memcpy(&pointer, reinterpret_cast<void*>(address), sizeof(pointer));
          const auto& field = dart::Object::Handle(zone, pointer);
          if (field.IsSmi() || field.IsMint() || field.IsString())
            std::printf("PUBLIC_DOWNLOAD_ENUM_PP[%ld] OFFSET[%ld] VALUE[%s]\n", (long)pp, (long)offset, field.ToCString());
        }
      }
    }
    // Selected public style/chunking enum identities only.
    for (intptr_t selected_pp : {29539,24883}) {
      const auto index = dart::ObjectPool::IndexFromOffset(selected_pp * 8 - dart::kHeapObjectTag);
      const auto& value = dart::Object::Handle(zone, pool.ObjectAt(index));
      if (value.IsInstance()) {
        const auto& cls = dart::Class::Handle(zone, dart::Instance::Cast(value).clazz());
        std::printf("PUBLIC_NOTE_ENUM_PP[%ld] CLASS[%s]\n", (long)selected_pp, dart::String::Handle(zone, cls.Name()).ToCString());
        const auto bitmap = isolate->group()->class_table()->GetUnboxedFieldsMapAt(value.GetClassId());
        for (intptr_t offset : {8, 16}) {
          if (offset >= cls.host_instance_size() || bitmap.Get(offset / 8)) continue;
          dart::ObjectPtr raw;
          std::memcpy(&raw, reinterpret_cast<void*>(dart::UntaggedObject::ToAddr(value.ptr()->untag()) + offset), sizeof(raw));
          const auto& field = dart::Object::Handle(zone, raw);
          if (field.IsString() || field.IsSmi()) std::printf("PUBLIC_NOTE_ENUM_PP[%ld] SLOT[%ld] VALUE[%s]\n", (long)selected_pp, (long)offset, field.ToCString());
        }
      }
    }
    // Selected public download URL fragments/schema labels only. Never inspect
    // credential PP9019 or any entire application configuration map.
    for (intptr_t pp : {24900,34522,12759,12760,24883,34496,34497,34498,34499,34500,34501,19662,34523,26609,34530,34531,34532,34533,34534,34535,34536,34540,34541,34542,34543,34544,34545,34546,34554,34590,34591,34592,34593,34602,34603,34604,34605,34606,34607,34608,34609,10614,9196,19651,1109,19655,19656,19658,19659,19671,19672,19673,34477,34478,34479,1112,19652,19654,8985,13036,13106,57,483,5327,1553,4523,13124,13125,13126,5320,1229,4714,4687,17024,17025,16982,17026,17027,13087,13090,13176,17017,17018,17019,10483,17021,2349}) {
      const auto index = dart::ObjectPool::IndexFromOffset(pp * 8 - dart::kHeapObjectTag);
      if (index < 0 || index >= pool.Length()) continue;
      if (pool.TypeAt(index) == dart::ObjectPool::EntryType::kImmediate) {
        std::printf("PUBLIC_DOWNLOAD_PP[%ld] IMMEDIATE[0x%lx]\n", (long)pp,
          (unsigned long)pool.RawValueAt(index));
        continue;
      }
      const auto& value = dart::Object::Handle(zone, pool.ObjectAt(index));
      if (value.IsString() || value.IsSmi() || value.IsMint() || value.IsDouble() || value.IsBool())
        std::printf("PUBLIC_DOWNLOAD_PP[%ld] CID[%ld] VALUE[%s]\n", (long)pp,
          (long)value.GetClassId(), value.ToCString());
      else
        std::printf("PUBLIC_DOWNLOAD_PP[%ld] CID[%ld] NONSCALAR_OMITTED\n", (long)pp,
          (long)value.GetClassId());
      if (pp == 34554 && value.IsArray()) {
        const auto& markers = dart::Array::Cast(value);
        for (intptr_t i=0; i<markers.Length(); ++i) {
          const auto& marker = dart::Object::Handle(zone, markers.At(i));
          if (marker.IsString())
            std::printf("PUBLIC_NOTE_STOP_MARKER[%ld] VALUE[%s]\n", (long)i, marker.ToCString());
        }
      }
      if ((pp == 19671 || pp == 19672 || pp == 19673) && value.IsRegExp()) {
        const auto& pattern = dart::String::Handle(zone, dart::RegExp::Cast(value).pattern());
        std::printf("PUBLIC_NOTE_REGEX_PP[%ld] PATTERN[%s]\n", (long)pp, pattern.ToCString());
      }
      if (pp == 13087 && value.IsInstance()) {
        const auto& cls = dart::Class::Handle(zone, dart::Instance::Cast(value).clazz());
        const auto& name = dart::String::Handle(zone, cls.Name());
        if (std::strcmp(name.ToCString(), "Duration") == 0 && cls.host_instance_size() >= 16) {
          const auto bitmap = isolate->group()->class_table()->GetUnboxedFieldsMapAt(value.GetClassId());
          if (bitmap.Get(1)) {
            int64_t microseconds;
            std::memcpy(&microseconds, reinterpret_cast<void*>(dart::UntaggedObject::ToAddr(value.ptr()->untag()) + 8), sizeof(microseconds));
            std::printf("PUBLIC_DOWNLOAD_DURATION_PP[13087] MICROSECONDS[%lld]\n", (long long)microseconds);
          }
        }
        if (value.GetClassId() == 315 && std::strcmp(name.ToCString(), "RetryOptions") == 0 && cls.host_instance_size() >= 32) {
          const auto bitmap = isolate->group()->class_table()->GetUnboxedFieldsMapAt(value.GetClassId());
          for (intptr_t offset : {8, 24}) {
            if (bitmap.Get(offset / 8)) continue;
            dart::ObjectPtr raw;
            std::memcpy(&raw, reinterpret_cast<void*>(dart::UntaggedObject::ToAddr(value.ptr()->untag()) + offset), sizeof(raw));
            const auto& field = dart::Object::Handle(zone, raw);
            if (field.IsString() || field.IsSmi() || field.IsMint() || field.IsDouble() || field.IsBool()) {
              std::printf("PUBLIC_DOWNLOAD_RETRY_PP[13087] OFFSET[%ld] VALUE[%s]\n", (long)offset, field.ToCString());
            } else if (field.IsInstance()) {
              const auto& field_cls = dart::Class::Handle(zone, dart::Instance::Cast(field).clazz());
              const auto& field_name = dart::String::Handle(zone, field_cls.Name());
              if (std::strcmp(field_name.ToCString(), "Duration") != 0 || field_cls.host_instance_size() < 16) continue;
              const auto field_bitmap = isolate->group()->class_table()->GetUnboxedFieldsMapAt(field.GetClassId());
              if (!field_bitmap.Get(1)) continue;
              int64_t microseconds;
              std::memcpy(&microseconds, reinterpret_cast<void*>(dart::UntaggedObject::ToAddr(field.ptr()->untag()) + 8), sizeof(microseconds));
              std::printf("PUBLIC_DOWNLOAD_RETRY_PP[13087] OFFSET[%ld] DURATION_MICROSECONDS[%lld]\n", (long)offset, (long long)microseconds);
            }
          }
        }
      }
    }

    for (intptr_t pp : {21086,21087,21088,1129,30668,30669,30672,28,30682,30683,30684,30685,30686,30687,8915,14907,21994,21998,9198,255,5212,508,5255,28510,19633,12416,18673,13325,14763,9735,14018,569,570,571,572,28443,28495,28497,28498,28499,28500,13185,1220,12673,12592,4121,7856,1188,19653,19657,10619,1207,13214,28511,30736,30737,30738,30739,30740,30741,30742,30743,30744,30745,30746,30747,30748,30749,30750,30751,30752,30753,30754,30755,30756,30757,30758,30759,30760,30761,30762,30763,30764,30765,30766,30767,30768,30769,30770,30771,30772,30773,30774,30775,30776,30777,30778,30779,30780,30781,30782,30783,30784,30785,30786,30787,30788,30789,30790,30791,30792,30793,30794,30795,30796,30797,30798,30799,30800,30801,30802,30803,30804,30805,30806,30807,30808,30809,30810,30811,30812,30813,30814,30815,30816,30817,30818,30819,30820,30821,30822,30823,30824,30825,30826,21993,21995,5213,1539,13184,11905,25010,5033,26962,30858,30827,30828,30829,30830,30831,30832,30833,30834,30835,30836,30837,30838,30839,1168,6379,6381,530,12651,12652,12653,12654,12655,12656,12657,12658,12659,12660,12661,12662,12663,12664,12665,12666,12667,12668,12669,12670,12671,12672,12673,12674,12675,12676,12677,12678,12679,12680,12681,12682,12683,12684,12685,12686,12687,12688,12689,12690,12691,12692,12693,12694,12695,12696,12697,12698,12699,12700,12701,12702,12703,12704,12705,31008,30099,30359,30611,30612,30613,30614,30731,1211,531,30991,30715,30716,30723,30724,30123,30598,31052,30688,30689,26977,1109,7976,12640,12600,12601,12602,12603,12604,12605,12606,12607,12608,12609,12610,12611,12612,12613,12614,12621,12622,12625,12626,12627,12628,12629,12630,12631,12634,12635,12636,12637,12638,12639,12641,12642,12643,12644,12645,4632,26969,4563,31045,9969,66,16,4659,10206,31046,31047,31049,4777,4924,4920,5265,8324,9779,3012,5279,10495,9018,8511,9018,9245,23909,23910,23911,23918,23926,23929,26597,26598,26599,26600,26601,26602,26604,26605,26606,2765,21048,9836,9089,4620,9663,82,20693,5845,26972,5940,3656,492,4518,4523,27,566,635,855,11631,22356,13118,11291,24954,24977,24980,24985,24986,26550,25030,25006,25007,4265,23921,11620,21079,26976,26978,26981,26989,26990,26995,26996,27001,27002,27003,27004,27424}) {
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

      if ((pp == 13325 || pp == 8915) && obj.IsInstance()) {
        const auto& instance = dart::Instance::Cast(obj);
        const auto& cls = dart::Class::Handle(zone, instance.clazz());
        for (intptr_t offset=8; offset<cls.host_instance_size() && offset<=16; offset+=8) {
          dart::ObjectPtr value;
          std::memcpy(&value, reinterpret_cast<void*>(dart::UntaggedObject::ToAddr(obj.ptr()->untag()) + offset), sizeof(value));
          const auto bitmap = isolate->group()->class_table()->GetUnboxedFieldsMapAt(obj.GetClassId());
          if (bitmap.Get(offset / 8)) {
            std::printf("ENUM_PP[%ld]_UNBOXED_SLOT[%ld] %lld\n", (long)pp, (long)offset, (long long)([&] { int64_t raw; std::memcpy(&raw, &value, sizeof(raw)); return raw; })());
            continue;
          }
          const auto& field = dart::Object::Handle(zone, value);
          if (field.IsSmi() || field.IsString())
            std::printf("ENUM_PP[%ld]_SLOT[%ld] %s\n", (long)pp, (long)offset, field.ToCString());
        }
      }
      if (pp == 11905 && obj.IsMap()) {
        const auto& map = dart::Map::Cast(obj);
        dart::Map::Iterator it(map);
        while (it.MoveNext()) {
          const auto& key = dart::Object::Handle(zone, it.CurrentKey());
          const auto& value = dart::Object::Handle(zone, it.CurrentValue());
          std::printf("MODEL_ENCRYPTION_POLICY KEY[%s] VALUE[%s]\n", key.ToCString(), value.ToCString());
          if (key.IsInstance()) {
            // Same ProtobufEnum layout already bound by toString.
            const auto tagged = dart::UntaggedObject::ToAddr(key.ptr()->untag()) + dart::kHeapObjectTag;
            int64_t enum_value; dart::ObjectPtr name_ptr;
            std::memcpy(&enum_value,reinterpret_cast<void*>(tagged+7),sizeof(enum_value));
            std::memcpy(&name_ptr,reinterpret_cast<void*>(tagged+15),sizeof(name_ptr));
            const auto& name = dart::Object::Handle(zone,name_ptr);
            std::printf("MODEL_ENCRYPTION_ENUM VALUE[%lld] NAME[%s]\n", (long long)enum_value, name.ToCString());
          }
        }
      }
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
      if (obj.IsString() && (pp == 21994 || pp == 21998 || pp == 9198 || pp == 255 || pp == 5212 || pp == 508 || pp == 5255 || pp == 9735 || pp == 14018 || (pp >= 569 && pp <= 572) || pp == 28443 || pp == 28495 || pp == 13185 || pp == 1220 || pp == 12673 || pp == 12592 || pp == 4121 || pp == 7856 || pp == 1188 || pp == 19653 || pp == 19657 || pp == 10619 || pp == 1207 || pp == 13214 || (pp >= 30736 && pp <= 30826) || pp == 21993 || pp == 21995 || pp == 5213 || pp == 1539 || (pp >= 12600 && pp <= 12705) || (pp >= 30827 && pp <= 30839) || pp == 11631 || pp == 1168 || pp == 6379 || pp == 6381 || pp == 530 || pp == 31045 || pp == 31046 || (pp >= 30611 && pp <= 30614) || pp == 31008 || pp == 30099 || pp == 30359 || pp == 30731 || pp == 1211 || pp == 531 || pp == 30991 || pp == 1109 || pp == 3656 || pp == 4265 || pp == 23921 || pp == 25006 || pp == 25007 || pp == 24980)) {
        const auto& str = dart::String::Cast(obj);
        std::printf("STRING_UNITS[%ld]",(long)pp);
        for (intptr_t j=0;j<str.Length();j++) std::printf(" %04x",str.CharAt(j));
        std::printf("\n");
      }
      if ((pp == 1129 || pp == 11620 || (pp >= 28497 && pp <= 28500)) && obj.IsInstance()) {
        const auto raw = dart::UntaggedObject::ToAddr(obj.ptr()->untag());
        int64_t stored; std::memcpy(&stored,reinterpret_cast<void*>(raw+8),sizeof(stored));
        const auto bitmap = isolate->group()->class_table()->GetUnboxedFieldsMapAt(obj.GetClassId());
        std::printf("DURATION_PP[%ld] FIELD[0x8] RAW[%lld] UNBOXED[%d]\n",(long)pp,(long long)stored,bitmap.Get(1));
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
    // Public export/label callback identities only; never print object contents.
    for (intptr_t pp : {34588,34589,34565,34526,34527,34552,24898,34525,34537,34538,34539,34511,34513,34518,34519,34502,34503,34610,19647,19648,24541,14905,14906,40651,40646,40647}) {
      const auto index = dart::ObjectPool::IndexFromOffset(pp * 8 - dart::kHeapObjectTag);
      const auto& callback = dart::Object::Handle(zone, pool.ObjectAt(index));
      if (callback.IsFunction()) {
        const auto& function = dart::Function::Cast(callback);
        std::printf("FUNCTION_PP[%ld] CODE_OFFSET[0x%lx]\n", (long)pp,
          (unsigned long)(function.entry_point() - reinterpret_cast<dart::uword>(image.lib)));
      }
      if (callback.IsClosure()) {
        const auto& function = dart::Function::Handle(zone, dart::Closure::Cast(callback).function());
        std::printf("CLOSURE_FUNCTION_PP[%ld] CODE_OFFSET[0x%lx]\n", (long)pp,
          (unsigned long)(function.entry_point() - reinterpret_cast<dart::uword>(image.lib)));
      }
    }
    std::printf("LIBC_CEIL_THREAD_OFFSET[%ld]\n", (long)dart::Thread::LibcCeil_entry_point_offset());
    std::printf("LIBC_ROUND_THREAD_OFFSET[%ld]\n", (long)dart::Thread::LibcRound_entry_point_offset());
    const auto origin = isolate->group()->dispatch_table()->ArrayOrigin();
    std::printf("LIST_ANY_DISPATCH CODE_OFFSET[0x%lx]\n",
      (unsigned long)(origin[dart::kGrowableObjectArrayCid + 41834] - reinterpret_cast<dart::uword>(image.lib)));
    std::printf("LIST_EMPTY_DISPATCH CODE_OFFSET[0x%lx]\n",
      (unsigned long)(origin[dart::kGrowableObjectArrayCid + 42110] - reinterpret_cast<dart::uword>(image.lib)));

    // ProdAppConfig getter reads only the "prod" entry of this environment map.
    // Do not print the map, configuration object, or any configuration fields.
    {
      const auto index = dart::ObjectPool::IndexFromOffset(13183 * 8 - dart::kHeapObjectTag);
      const auto& environments = dart::Object::Handle(zone, pool.ObjectAt(index));
      if (environments.IsMap()) {
        dart::Map::Iterator it(dart::Map::Cast(environments));
        while (it.MoveNext()) {
          const auto& key = dart::Object::Handle(zone, it.CurrentKey());
          if (!key.IsString() || std::strcmp(key.ToCString(), "prod") != 0) continue;
          const auto& selected = dart::Object::Handle(zone, it.CurrentValue());
          const auto cid = selected.GetClassId();
          std::printf("PROD_CONFIG_CID[%ld] GETTER_723_CODE_OFFSET[0x%lx]\n", (long)cid,
            (unsigned long)(origin[cid + 723] - reinterpret_cast<dart::uword>(image.lib)));
          const auto key_index = dart::ObjectPool::IndexFromOffset(13185 * 8 - dart::kHeapObjectTag);
          const auto& service_key = dart::Object::Handle(zone, pool.ObjectAt(key_index));
          if (selected.IsMap() && service_key.IsString()) {
            dart::Map::Iterator fields(dart::Map::Cast(selected));
            while (fields.MoveNext()) {
              const auto& field_key = dart::Object::Handle(zone, fields.CurrentKey());
              if (!field_key.IsString() ||
                  !dart::String::Cast(field_key).Equals(dart::String::Cast(service_key))) continue;
              const auto& service = dart::Object::Handle(zone, fields.CurrentValue());
              if (service.IsString()) std::printf("MODEL_KEYCHAIN_SERVICE[%s]\n", service.ToCString());
            }
          }
        }
      }
    }

    // Resolve only the public encryption-service methods called by AssetManager.
    // Do not inspect key objects or keychain contents.
    const auto class_table = isolate->group()->class_table();
    for (intptr_t cid=0; cid<class_table->NumCids(); cid++) {
      if (!class_table->HasValidClassAt(cid)) continue;
      const auto& cls = dart::Class::Handle(zone, class_table->At(cid));
      const auto& name = dart::String::Handle(zone, cls.Name());
      if (cid == 58 || cid == 315 || cid == 1517 || cid == 1518 || cid == 1519 || cid == 5529 || cid == 6128)
        std::printf("PUBLIC_DOWNLOAD_CLASS CID[%ld] NAME[%s]\n", (long)cid, name.ToCString());
      if (cid == 315 && std::strcmp(name.ToCString(), "RetryOptions") == 0) {
        const auto& fields = dart::Array::Handle(zone, cls.fields());
        for (intptr_t j=0; j<fields.Length(); j++) {
          const auto& field = dart::Field::Handle(zone, dart::Field::RawCast(fields.At(j)));
          if (!field.is_static())
            std::printf("PUBLIC_DOWNLOAD_RETRY_FIELD OFFSET[%ld] NAME[%s]\n",
              (long)field.HostOffset(), dart::String::Handle(zone, field.name()).ToCString());
        }
      }
      if (std::strcmp(name.ToCString(), "Note") == 0 ||
          std::strcmp(name.ToCString(), "CalendarEvent") == 0) {
        const auto& fields = dart::Array::Handle(zone, cls.fields());
        std::printf("EXPORT_CLASS[%s] CID[%ld] FIELD_COUNT[%ld]\n",
          name.ToCString(), (long)cid, (long)fields.Length());
        for (intptr_t j=0; j<fields.Length(); j++) {
          const auto& field = dart::Field::Handle(zone, dart::Field::RawCast(fields.At(j)));
          if (!field.is_static())
            std::printf("EXPORT_CLASS[%s] FIELD_OFFSET[%ld] FIELD[%s]\n",
              name.ToCString(), (long)field.HostOffset(), field.ToCString());
        }
      }
      if (std::strcmp(name.ToCString(), "MacosEncryptionService") != 0) continue;
      std::printf("ENCRYPTION_CLASS CID[%ld] NAME[%s]\n", (long)cid, name.ToCString());
      for (intptr_t offset : {-4096,-4092,-4085}) {
        const auto entry = origin[cid + offset];
        std::printf("ENCRYPTION_DISPATCH[%ld] CODE_OFFSET[0x%lx]\n",
          (long)offset,(unsigned long)(entry - reinterpret_cast<dart::uword>(image.lib)));
      }
    }
    for (intptr_t offset : {0,-4094,-4092,-4090,-4096,-4086,23776}) {
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
