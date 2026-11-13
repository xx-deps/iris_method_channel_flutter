import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:iris_method_channel/src/platform/iris_event_interface.dart';
import 'package:iris_method_channel/src/platform/iris_method_channel_interface.dart';

// ignore_for_file: public_member_api_docs, non_constant_identifier_names

// NOTE:
// This file is compiled to both dart2js and dart2wasm, so it only uses the
// `dart:js_interop` APIs, which are supported on both compilers.

@JS('IrisCore.EventParam')
@anonymous
extension type EventParam._(JSObject _) implements JSObject {
  external factory EventParam({
    String event,
    String data,
    int data_size,
    String result,
    JSArray<JSObject>? buffer,
    JSArray<JSNumber>? length,
    int buffer_count,
  });

  external String get event;
  external String get data;
  external int get data_size;
  external String get result;
  external JSArray<JSObject> get buffer;
  external JSArray<JSNumber> get length;
  external int get buffer_count;
}

Uint8List _jsObjectToUint8List(JSObject o) {
  if (o.isA<JSUint8Array>()) {
    return (o as JSUint8Array).toDart;
  }
  if (o.isA<JSArrayBuffer>()) {
    return (o as JSArrayBuffer).toDart.asUint8List();
  }
  return Uint8List(0);
}

IrisEventMessage toIrisEventMessage(EventParam param) {
  return IrisEventMessage(param.event, param.data,
      param.buffer.toDart.map(_jsObjectToUint8List).toList());
}

typedef ApiParam = EventParam;

@JS('IrisCore.CallIrisApiResult')
@anonymous
extension type CallIrisApiResult._(JSObject _) implements JSObject {
  external factory CallIrisApiResult({
    int code,
    String data,
  });

  external int get code;
  external String get data;
}

extension CallIrisApiResultExt on CallIrisApiResult {
  CallApiResult toCallApiResult() {
    return CallApiResult(
        irisReturnCode: code, data: jsonDecode(data), rawData: data);
  }
}

@JS('IrisCore.IrisEventHandler')
@anonymous
extension type IrisEventHandler._(JSObject _) implements JSObject {}

@JS('IrisCore.IrisApiEngine')
@anonymous
extension type IrisApiEngine._(JSObject _) implements JSObject {}

@JS('IrisCore.createIrisApiEngine')
external IrisApiEngine createIrisApiEngine();

@JS('IrisCore.disposeIrisApiEngine')
external int disposeIrisApiEngine(IrisApiEngine engine_ptr);

// NOTE: The JS side returns a `Promise` of a `CallIrisApiResult`. The return
// type stays `JSAny` so existing callers keep their own conversion, e.g.
// `(callIrisApi(...) as JSPromise<CallIrisApiResult>).toDart`.
@JS('IrisCore.callIrisApi')
external JSAny callIrisApi(IrisApiEngine engine_ptr, ApiParam apiParam);

typedef IrisEventHandlerFuncJS = void Function(EventParam param);
typedef IrisCEventHandler = IrisEventHandlerFuncJS;

// A plain Dart function type is not allowed in an `external` interop
// signature, so the JS declaration takes a `JSObject` and the exported
// wrapper converts the callback with `Function.toJS` (dart2js + dart2wasm).
@JS('IrisCore.createIrisEventHandler')
external IrisEventHandler _createIrisEventHandler(JSObject event_handler);

IrisEventHandler createIrisEventHandler(IrisCEventHandler event_handler) =>
    _createIrisEventHandler(event_handler.toJS);
