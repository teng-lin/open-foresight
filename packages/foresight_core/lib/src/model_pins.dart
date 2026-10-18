import 'dart:convert';

// Canonical JSON shared by the Dart catalogs and Python acceptance tooling.
// The literal is compiled into Dart releases; runtime filesystem access is not
// required. Python requires exactly one pair of these marker lines.
// BEGIN FORESIGHT MODEL PINS
const modelPinsJson = r'''
[
  {
    "name": "Gemma 4 12B",
    "repository": "litert-community/gemma-4-12B-it-litert-lm",
    "revision": "7a0b1ce0ea821bcd01c5f72af84155e02191152f",
    "filename": "gemma-4-12B-it.litertlm",
    "sha256": "58fd31b778ca2c21c80d634fb34fc5a89d11d563a38dfd3cbf1b40dbf252a8b6",
    "bytes": 6883278368,
    "minimumMemoryGb": 30
  },
  {
    "name": "Gemma 4 E4B",
    "repository": "litert-community/gemma-4-E4B-it-litert-lm",
    "revision": "2eee7ac325f20eb8c9ac1d0e972f7c84663062da",
    "filename": "gemma-4-E4B-it.litertlm",
    "sha256": "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0",
    "bytes": 3659530240,
    "minimumMemoryGb": 15
  },
  {
    "name": "Gemma 4 E2B",
    "repository": "litert-community/gemma-4-E2B-it-litert-lm",
    "revision": "b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1",
    "filename": "gemma-4-E2B-it.litertlm",
    "sha256": "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
    "bytes": 2588147712,
    "minimumMemoryGb": 6
  },
  {
    "name": "EmbeddingGemma 2",
    "repository": "litert-community/embeddinggemma-2-740m-litert-lm",
    "revision": "24d962e906c7d332c6428e71c9676855024569e2",
    "filename": "embeddinggemma-2-740m.litertlm",
    "sha256": "e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c",
    "bytes": 484622336,
    "minimumMemoryGb": 0
  },
  {
    "name": "Whisper Tiny",
    "repository": "ggerganov/whisper.cpp",
    "revision": "5359861c739e955e79d9a303bcbc70fb988958b1",
    "filename": "ggml-tiny.bin",
    "sha256": "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
    "bytes": 77691713,
    "minimumMemoryGb": 0
  },
  {
    "name": "Whisper Base",
    "repository": "ggerganov/whisper.cpp",
    "revision": "5359861c739e955e79d9a303bcbc70fb988958b1",
    "filename": "ggml-base.bin",
    "sha256": "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
    "bytes": 147951465,
    "minimumMemoryGb": 0
  },
  {
    "name": "Whisper Small",
    "repository": "ggerganov/whisper.cpp",
    "revision": "5359861c739e955e79d9a303bcbc70fb988958b1",
    "filename": "ggml-small.bin",
    "sha256": "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
    "bytes": 487601967,
    "minimumMemoryGb": 0
  },
  {
    "name": "Whisper Medium",
    "repository": "ggerganov/whisper.cpp",
    "revision": "5359861c739e955e79d9a303bcbc70fb988958b1",
    "filename": "ggml-medium.bin",
    "sha256": "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
    "bytes": 1533763059,
    "minimumMemoryGb": 0
  },
  {
    "name": "Whisper Large v3 Turbo",
    "repository": "ggerganov/whisper.cpp",
    "revision": "5359861c739e955e79d9a303bcbc70fb988958b1",
    "filename": "ggml-large-v3-turbo.bin",
    "sha256": "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
    "bytes": 1624555275,
    "minimumMemoryGb": 0
  }
]
''';
// END FORESIGHT MODEL PINS

final modelPins = List<Map<String, dynamic>>.unmodifiable(
  (jsonDecode(modelPinsJson) as List).map(
    (value) => Map<String, dynamic>.unmodifiable(value as Map<String, dynamic>),
  ),
);

Map<String, dynamic> modelPin(String filename) =>
    modelPins.singleWhere((pin) => pin['filename'] == filename);
