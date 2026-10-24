import 'dart:async';
import 'package:grpc/grpc.dart';
// Shared fixtures exercise internal wire protocol types.
// ignore: implementation_imports
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';

class DelayedIndexService extends RagServiceBase {
  final started = Completer<void>(), release = Completer<void>();
  int calls = 0;
  ServiceCall? indexCall;
  final configurations = <UpdateModelPathsRequest>[];
  @override
  Future<UpdateModelPathsResponse> updateModelPaths(
    ServiceCall call,
    UpdateModelPathsRequest request,
  ) async {
    configurations.add(request);
    return UpdateModelPathsResponse(success: true);
  }

  @override
  Future<IndexResponse> indexDocument(
    ServiceCall call,
    IndexRequest request,
  ) async {
    calls++;
    indexCall = call;
    if (!started.isCompleted) started.complete();
    await release.future;
    return IndexResponse(success: true);
  }

  @override
  Future<DeleteResponse> deleteDocument(
    ServiceCall call,
    DeleteRequest request,
  ) async => DeleteResponse(success: true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
