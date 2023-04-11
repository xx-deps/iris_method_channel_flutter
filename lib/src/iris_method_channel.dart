import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';
import 'package:async/async.dart';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart'
    show SynchronousFuture, VoidCallback, visibleForTesting;
import 'package:iris_method_channel/src/iris_event.dart';
import 'package:iris_method_channel/src/native_bindings_delegate.dart';
import 'package:iris_method_channel/src/scoped_objects.dart';
import 'bindings/native_iris_api_common_bindings.dart' as iris;

// ignore_for_file: public_member_api_docs

class IrisMethodCall {
  const IrisMethodCall(this.funcName, this.params,
      {this.buffers, this.rawBufferParams});
  final String funcName;
  final String params;
  final List<Uint8List>? buffers;
  final List<BufferParam>? rawBufferParams;
}

const int kBasicResultLength = 64 * 1024;
const int kDisposedIrisMethodCallReturnCode = 1000;
const Map<String, int> kDisposedIrisMethodCallData = {'result': 0};

class CallApiResult {
  CallApiResult(
      {required this.irisReturnCode, required this.data, this.rawData = ''});

  final int irisReturnCode;

  final Map<String, dynamic> data;

  // TODO(littlegnal): Remove rawData after EP-253 landed.
  final String rawData;
}

class _EventHandlerHolderKey implements ScopedKey {
  const _EventHandlerHolderKey({
    required this.registerName,
    required this.unregisterName,
  });
  final String registerName;
  final String unregisterName;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is _EventHandlerHolderKey &&
        other.registerName == registerName &&
        other.unregisterName == unregisterName;
  }

  @override
  int get hashCode => Object.hash(registerName, unregisterName);
}

@visibleForTesting
class EventHandlerHolder
    with ScopedDisposableObjectMixin
    implements DisposableObject {
  EventHandlerHolder({required this.key});
  final _EventHandlerHolderKey key;
  final Set<EventLoopEventHandler> _eventHandlers = {};

  int nativeEventHandlerIntPtr = 0;

  void addEventHandler(EventLoopEventHandler eventHandler) {
    _eventHandlers.add(eventHandler);
  }

  Future<void> removeEventHandler(EventLoopEventHandler eventHandler) async {
    _eventHandlers.remove(eventHandler);
  }

  Set<EventLoopEventHandler> getEventHandlers() => _eventHandlers;

  @override
  Future<void> dispose() {
    _eventHandlers.clear();
    return SynchronousFuture(null);
  }
}

Uint8List uint8ListFromPtr(int intPtr, int length) {
  final ptr = ffi.Pointer<ffi.Uint8>.fromAddress(intPtr);
  final memoryList = ptr.asTypedList(length);
  return Uint8List.fromList(memoryList);
}

ffi.Pointer<ffi.Void> uint8ListToPtr(Uint8List buffer) {
  ffi.Pointer<ffi.Void> bufferPointer;

  final ffi.Pointer<ffi.Uint8> bufferData =
      calloc.allocate<ffi.Uint8>(buffer.length);

  final pointerList = bufferData.asTypedList(buffer.length);
  pointerList.setAll(0, buffer);

  bufferPointer = bufferData.cast<ffi.Void>();
  return bufferPointer;
}

void freePointer(ffi.Pointer<ffi.Void> ptr) {
  calloc.free(ptr);
}

class _Messenger implements DisposableObject {
  _Messenger(this.requestPort, this.responseQueue);
  final SendPort requestPort;
  final StreamQueue<dynamic> responseQueue;
  bool _isDisposed = false;

  Future<CallApiResult> send(_Request request) async {
    if (_isDisposed) {
      return CallApiResult(
          irisReturnCode: kDisposedIrisMethodCallReturnCode,
          data: kDisposedIrisMethodCallData);
    }
    requestPort.send(request);
    return await responseQueue.next;
  }

  Future<List<CallApiResult>> listSend(_Request request) async {
    if (_isDisposed) {
      return [
        CallApiResult(
            irisReturnCode: kDisposedIrisMethodCallReturnCode,
            data: kDisposedIrisMethodCallData)
      ];
    }
    requestPort.send(request);
    return await responseQueue.next;
  }

  @override
  Future<void> dispose() async {
    if (!_isDisposed) return;
    _isDisposed = true;
    requestPort.send(null);
    await responseQueue.cancel();
  }
}

class _InitilizationArgs {
  _InitilizationArgs(
    this.apiCallPortSendPort,
    this.eventPortSendPort,
    this.onExitSendPort,
    this.provider,
    this.argNativeHandles,
  );

  final SendPort apiCallPortSendPort;
  final SendPort eventPortSendPort;
  final SendPort? onExitSendPort;
  final NativeBindingsProvider provider;
  final List<int> argNativeHandles;
}

class InitilizationResult {
  InitilizationResult(
    this._apiCallPortSendPort,
    this.irisApiEngineNativeHandle,
    this.extraData,
    this._debugIrisCEventHandlerNativeHandle,
    this._debugIrisEventHandlerNativeHandle,
  );

  final SendPort _apiCallPortSendPort;
  final int irisApiEngineNativeHandle;

  /// Same as [CreateNativeApiEngineResult.extraData]
  final Map<String, Object> extraData;

  final int? _debugIrisCEventHandlerNativeHandle;
  final int? _debugIrisEventHandlerNativeHandle;
}

/// Listener when hot restarted.
///
/// You can release some native resources, such like delete the pointer which is
/// created by ffi.
///
/// NOTE that:
/// * This listener is only received on debug mode.
/// * You should not comunicate with the [IrisMethodChannel] anymore inside this listener.
/// * You should not do some asynchronous jobs inside this listener.
typedef HotRestartListener = void Function(Object? message);

class _HotRestartFinalizer {
  _HotRestartFinalizer(this.provider) {
    assert(() {
      _onExitPort = ReceivePort();
      _onExitSubscription = _onExitPort?.listen((message) {
        _finalize(message);
      });

      return true;
    }());
  }

  final NativeBindingsProvider provider;

  final List<HotRestartListener> _hotRestartListeners = [];

  ReceivePort? _onExitPort;
  StreamSubscription? _onExitSubscription;

  SendPort? get onExitSendPort => _onExitPort?.sendPort;

  bool _isFinalize = false;

  int? _debugIrisApiEngineNativeHandle;
  set debugIrisApiEngineNativeHandle(int value) {
    _debugIrisApiEngineNativeHandle = value;
  }

  int? _debugIrisCEventHandlerNativeHandle;
  set debugIrisCEventHandlerNativeHandle(int? value) {
    _debugIrisCEventHandlerNativeHandle = value;
  }

  int? _debugIrisEventHandlerNativeHandle;
  set debugIrisEventHandlerNativeHandle(int? value) {
    _debugIrisEventHandlerNativeHandle = value;
  }

  void _finalize(dynamic msg) {
    if (_isFinalize) {
      return;
    }
    _isFinalize = true;

    // We will receive a value of `0` as message when the `IrisMethodChannel.dispose`
    // is called normally, which will call the `Isolate.exit(onExitSendPort, 0)`
    // to send a value of `0` as a exit response. See `_execute` function for more detail.
    if (msg != null && msg == 0) {
      return;
    }

    for (final listener in _hotRestartListeners.reversed) {
      listener(msg);
    }

    // When hot restart happen, the `IrisMethodChannel.dispose` function will not
    // be called normally, cause the native API engine can not be destroy correctly,
    // so we need to release the native resources which create by the
    // `NativeBindingDelegate` explicitly.
    final nativeBindingDelegate = provider.provideNativeBindingDelegate();
    nativeBindingDelegate.initialize();

    nativeBindingDelegate.destroyNativeApiEngine(
        ffi.Pointer.fromAddress(_debugIrisApiEngineNativeHandle!));

    calloc.free(ffi.Pointer.fromAddress(_debugIrisCEventHandlerNativeHandle!));
    nativeBindingDelegate.destroyIrisEventHandler(
        ffi.Pointer.fromAddress(_debugIrisEventHandlerNativeHandle!));

    final irisEvent = provider.provideIrisEvent();
    irisEvent.dispose();

    _onExitSubscription?.cancel();
  }

  VoidCallback addHotRestartListener(HotRestartListener listener) {
    assert(() {
      final Object? debugCheckForReturnedFuture = listener as dynamic;
      if (debugCheckForReturnedFuture is Future) {
        throw UnsupportedError(
            'HotRestartListener must be a void method without an `async` keyword.');
      }
      return true;
    }());

    _hotRestartListeners.add(listener);
    return () {
      removeHotRestartListener(listener);
    };
  }

  void removeHotRestartListener(HotRestartListener listener) {
    _hotRestartListeners.remove(listener);
  }

  void dispose() {
    _hotRestartListeners.clear();
  }
}

class IrisMethodChannel {
  IrisMethodChannel(this._nativeBindingsProvider);

  final NativeBindingsProvider _nativeBindingsProvider;

  bool _initilized = false;
  late _Messenger messenger;
  late StreamSubscription evntSubscription;
  @visibleForTesting
  final ScopedObjects scopedEventHandlers = ScopedObjects();
  late int _nativeHandle;

  @visibleForTesting
  late Isolate workerIsolate;
  late _HotRestartFinalizer _hotRestartFinalizer;

  static Future<void> _execute(_InitilizationArgs args) async {
    SendPort mainApiCallSendPort = args.apiCallPortSendPort;
    SendPort mainEventSendPort = args.eventPortSendPort;
    SendPort? onExitSendPort = args.onExitSendPort;
    NativeBindingsProvider provider = args.provider;

    List<ffi.Pointer<ffi.Void>> argsInner = args.argNativeHandles
        .map<ffi.Pointer<ffi.Void>>((e) => ffi.Pointer.fromAddress(e))
        .toList();

    final apiCallPort = ReceivePort();

    final nativeBindingDelegate = provider.provideNativeBindingDelegate();
    final irisEvent = provider.provideIrisEvent();

    _IrisMethodChannelNative executor =
        _IrisMethodChannelNative(nativeBindingDelegate, irisEvent);
    CreateNativeApiEngineResult executorInitilizationResult =
        executor.initilize(mainEventSendPort, argsInner);

    int? debugIrisCEventHandlerNativeHandle;
    int? debugIrisEventHandlerNativeHandle;

    assert(() {
      debugIrisCEventHandlerNativeHandle =
          executor.irisCEventHandlerNativeHandle;
      debugIrisEventHandlerNativeHandle = executor.irisEventHandlerNativeHandle;

      return true;
    }());

    final InitilizationResult initilizationResponse = InitilizationResult(
      apiCallPort.sendPort,
      executor.irisApiEngineNativeHandle,
      executorInitilizationResult.extraData,
      debugIrisCEventHandlerNativeHandle,
      debugIrisEventHandlerNativeHandle,
    );

    mainApiCallSendPort.send(initilizationResponse);

    // Wait for messages from the main isolate.
    await for (final request in apiCallPort) {
      if (request == null) {
        // Exit if the main isolate sends a null message, indicating there are no
        // more files to read and parse.
        break;
      }

      assert(request is _Request);

      if (request is _ApiCallRequest) {
        final result = executor.invokeMethod(request.methodCall);

        mainApiCallSendPort.send(result);
      } else if (request is _ApiCallListRequest) {
        final results = <CallApiResult>[];
        for (final methodCall in request.methodCalls) {
          final result = executor.invokeMethod(methodCall);
          results.add(result);
        }

        mainApiCallSendPort.send(results);
      } else if (request is _CreateNativeEventHandlerRequest) {
        final result = executor.createNativeEventHandler(request.methodCall);
        mainApiCallSendPort.send(result);
      } else if (request is _CreateNativeEventHandlerListRequest) {
        final results = <CallApiResult>[];
        for (final methodCall in request.methodCalls) {
          final result = executor.createNativeEventHandler(methodCall);
          results.add(result);
        }

        mainApiCallSendPort.send(results);
      } else if (request is _DestroyNativeEventHandlerRequest) {
        final result = executor.destroyNativeEventHandler(request.methodCall);
        mainApiCallSendPort.send(result);
      } else if (request is _DestroyNativeEventHandlerListRequest) {
        final results = <CallApiResult>[];
        for (final methodCall in request.methodCalls) {
          final result = executor.destroyNativeEventHandler(methodCall);
          results.add(result);
        }

        mainApiCallSendPort.send(results);
      }
    }

    executor.dispose();
    Isolate.exit(onExitSendPort, 0);
  }

  Future<InitilizationResult?> initilize(List<int> args) async {
    if (_initilized) return null;

    final apiCallPort = ReceivePort();
    final eventPort = ReceivePort();

    _hotRestartFinalizer = _HotRestartFinalizer(_nativeBindingsProvider);

    workerIsolate = await Isolate.spawn(
      _execute,
      _InitilizationArgs(
        apiCallPort.sendPort,
        eventPort.sendPort,
        _hotRestartFinalizer.onExitSendPort,
        _nativeBindingsProvider,
        args,
      ),
      onExit: _hotRestartFinalizer.onExitSendPort,
    );

    // Convert the ReceivePort into a StreamQueue to receive messages from the
    // spawned isolate using a pull-based interface. Events are stored in this
    // queue until they are accessed by `events.next`.
    // final events = StreamQueue<dynamic>(p);
    final responseQueue = StreamQueue<dynamic>(apiCallPort);

    // The first message from the spawned isolate is a SendPort. This port is
    // used to communicate with the spawned isolate.
    // SendPort sendPort = await events.next;
    final msg = await responseQueue.next;
    assert(msg is InitilizationResult);
    final initilizationResult = msg as InitilizationResult;
    final requestPort = initilizationResult._apiCallPortSendPort;
    _nativeHandle = initilizationResult.irisApiEngineNativeHandle;

    assert(() {
      _hotRestartFinalizer.debugIrisApiEngineNativeHandle =
          initilizationResult.irisApiEngineNativeHandle;
      _hotRestartFinalizer.debugIrisCEventHandlerNativeHandle =
          initilizationResult._debugIrisCEventHandlerNativeHandle;
      _hotRestartFinalizer.debugIrisEventHandlerNativeHandle =
          initilizationResult._debugIrisEventHandlerNativeHandle;

      return true;
    }());

    messenger = _Messenger(requestPort, responseQueue);

    evntSubscription = eventPort.listen((message) {
      if (!_initilized) {
        return;
      }

      final eventMessage = IrisEvent.parseMessage(message);

      bool handled = false;
      for (final sub in scopedEventHandlers.values) {
        final scopedObjects = sub as DisposableScopedObjects;
        for (final es in scopedObjects.values) {
          final EventHandlerHolder eh = es as EventHandlerHolder;
          // We need the event handlers with the same _EventHandlerHolderKey consume the message.
          for (final e in eh.getEventHandlers()) {
            if (e.handleEvent(
                eventMessage.event, eventMessage.data, eventMessage.buffers)) {
              handled = true;
            }
          }

          // Break the loop after the event handlers in the same EventHandlerHolder
          // consume the message.
          if (handled) {
            break;
          }
        }

        // Break the loop if there is an EventHandlerHolder consume the message.
        if (handled) {
          break;
        }
      }
    });

    _initilized = true;

    return initilizationResult;
  }

  Future<CallApiResult> invokeMethod(IrisMethodCall methodCall) async {
    if (!_initilized) {
      return CallApiResult(
          irisReturnCode: kDisposedIrisMethodCallReturnCode,
          data: kDisposedIrisMethodCallData);
    }
    final CallApiResult result =
        await messenger.send(_ApiCallRequest(methodCall));

    return result;
  }

  Future<List<CallApiResult>> invokeMethodList(
      List<IrisMethodCall> methodCalls) async {
    if (!_initilized) {
      return methodCalls
          .map((e) => CallApiResult(
              irisReturnCode: kDisposedIrisMethodCallReturnCode,
              data: kDisposedIrisMethodCallData))
          .toList();
    }

    final List<CallApiResult> result =
        await messenger.listSend(_ApiCallListRequest(methodCalls));

    return result;
  }

  Future<void> dispose() async {
    if (!_initilized) return;
    _initilized = false;
    _hotRestartFinalizer.dispose();
    await scopedEventHandlers.clear();
    await evntSubscription.cancel();

    await messenger.dispose();
  }

  Future<CallApiResult> registerEventHandler(
      ScopedEvent scopedEvent, String params) async {
    if (!_initilized) {
      return CallApiResult(
          irisReturnCode: kDisposedIrisMethodCallReturnCode,
          data: kDisposedIrisMethodCallData);
    }

    final DisposableScopedObjects subScopedObjects = scopedEventHandlers
        .putIfAbsent(scopedEvent.scopedKey, () => DisposableScopedObjects());
    final eventKey = _EventHandlerHolderKey(
      registerName: scopedEvent.registerName,
      unregisterName: scopedEvent.unregisterName,
    );
    final EventHandlerHolder holder = subScopedObjects.putIfAbsent(
        eventKey,
        () => EventHandlerHolder(
              key: _EventHandlerHolderKey(
                registerName: scopedEvent.registerName,
                unregisterName: scopedEvent.unregisterName,
              ),
            ));

    late CallApiResult result;
    if (holder.getEventHandlers().isEmpty) {
      result = await messenger.send(_CreateNativeEventHandlerRequest(
          IrisMethodCall(eventKey.registerName, params)));

      final nativeEventHandlerIntPtr = result.data['observerIntPtr']!;
      holder.nativeEventHandlerIntPtr = nativeEventHandlerIntPtr;
    } else {
      result = CallApiResult(irisReturnCode: 0, data: {'result': 0});
    }

    holder.addEventHandler(scopedEvent.handler);

    return result;
  }

  Future<CallApiResult> unregisterEventHandler(
      ScopedEvent scopedEvent, String params) async {
    if (!_initilized) {
      return CallApiResult(
          irisReturnCode: kDisposedIrisMethodCallReturnCode,
          data: kDisposedIrisMethodCallData);
    }

    final DisposableScopedObjects? subScopedObjects =
        scopedEventHandlers.get(scopedEvent.scopedKey);
    final eventKey = _EventHandlerHolderKey(
      registerName: scopedEvent.registerName,
      unregisterName: scopedEvent.unregisterName,
    );
    final EventHandlerHolder? holder = subScopedObjects?.get(eventKey);
    late CallApiResult result;
    if (holder != null) {
      holder.removeEventHandler(scopedEvent.handler);
      if (holder.getEventHandlers().isEmpty) {
        result = await messenger.send(_DestroyNativeEventHandlerRequest(
          IrisMethodCall(
            scopedEvent.unregisterName,
            params,
            rawBufferParams: [BufferParam(holder.nativeEventHandlerIntPtr, 1)],
          ),
        ));

        return result;
      }
    }

    result = CallApiResult(irisReturnCode: 0, data: {'result': 0});
    return result;
  }

  Future<void> unregisterEventHandlers(TypedScopedKey scopedKey) async {
    if (!_initilized) {
      return;
    }

    final DisposableScopedObjects? subScopedObjects =
        scopedEventHandlers.remove(scopedKey);
    if (subScopedObjects != null) {
      for (final eventKey in subScopedObjects.keys) {
        final EventHandlerHolder? holder = subScopedObjects.get(eventKey);
        if (holder != null) {
          final methodCalls = holder
              .getEventHandlers()
              .map((e) => IrisMethodCall(
                    holder.key.unregisterName,
                    '',
                    rawBufferParams: [
                      BufferParam(holder.nativeEventHandlerIntPtr, 1)
                    ],
                  ))
              .toList();

          await messenger
              .listSend(_DestroyNativeEventHandlerListRequest(methodCalls));

          await holder.dispose();
        }
      }

      await subScopedObjects.dispose();
    }
  }

  int getNativeHandle() {
    if (!_initilized) {
      return 0;
    }

    return _nativeHandle;
  }

  VoidCallback addHotRestartListener(HotRestartListener listener) {
    return _hotRestartFinalizer.addHotRestartListener(listener);
  }

  void removeHotRestartListener(HotRestartListener listener) {
    _hotRestartFinalizer.removeHotRestartListener(listener);
  }
}

abstract class _Request {}

abstract class _IrisMethodCallRequest implements _Request {
  const _IrisMethodCallRequest(this.methodCall);

  final IrisMethodCall methodCall;
}

abstract class _IrisMethodCallListRequest implements _Request {
  const _IrisMethodCallListRequest(this.methodCalls);

  final List<IrisMethodCall> methodCalls;
}

class _ApiCallRequest extends _IrisMethodCallRequest {
  const _ApiCallRequest(IrisMethodCall methodCall) : super(methodCall);
}

// ignore: unused_element
class _ApiCallListRequest extends _IrisMethodCallListRequest {
  const _ApiCallListRequest(List<IrisMethodCall> methodCalls)
      : super(methodCalls);
}

class _CreateNativeEventHandlerRequest extends _IrisMethodCallRequest {
  const _CreateNativeEventHandlerRequest(IrisMethodCall methodCall)
      : super(methodCall);
}

// ignore: unused_element
class _CreateNativeEventHandlerListRequest extends _IrisMethodCallListRequest {
  const _CreateNativeEventHandlerListRequest(List<IrisMethodCall> methodCalls)
      : super(methodCalls);
}

class _DestroyNativeEventHandlerRequest extends _IrisMethodCallRequest {
  const _DestroyNativeEventHandlerRequest(IrisMethodCall methodCall)
      : super(methodCall);
}

class _DestroyNativeEventHandlerListRequest extends _IrisMethodCallListRequest {
  const _DestroyNativeEventHandlerListRequest(List<IrisMethodCall> methodCalls)
      : super(methodCalls);
}

class _IrisMethodChannelNative {
  _IrisMethodChannelNative(this._nativeIrisApiEngineBinding, this._irisEvent);
  final NativeBindingDelegate _nativeIrisApiEngineBinding;

  ffi.Pointer<ffi.Void>? _irisApiEnginePtr;
  int get irisApiEngineNativeHandle {
    assert(_irisApiEnginePtr != null);
    return _irisApiEnginePtr!.address;
  }

  final IrisEvent _irisEvent;
  ffi.Pointer<iris.IrisCEventHandler>? _irisCEventHandler;
  int get irisCEventHandlerNativeHandle {
    assert(_irisCEventHandler != null);
    return _irisCEventHandler!.address;
  }

  ffi.Pointer<ffi.Void>? _irisEventHandler;
  int get irisEventHandlerNativeHandle {
    assert(_irisEventHandler != null);
    return _irisEventHandler!.address;
  }

  CreateNativeApiEngineResult initilize(
      SendPort sendPort, List<ffi.Pointer<ffi.Void>> args) {
    _irisEvent.initialize();
    _nativeIrisApiEngineBinding.initialize();

    final createResult =
        _nativeIrisApiEngineBinding.createNativeApiEngine(args);
    _irisApiEnginePtr = createResult.apiEnginePtr;

    _irisEvent.registerEventHandler(sendPort);

    _irisCEventHandler = calloc<iris.IrisCEventHandler>()
      ..ref.OnEvent = _irisEvent.onEventPtr.cast();

    _irisEventHandler =
        _nativeIrisApiEngineBinding.createIrisEventHandler(_irisCEventHandler!);

    return createResult;
  }

  CallApiResult _invokeMethod(IrisMethodCall methodCall) {
    assert(_irisApiEnginePtr != null, 'Make sure initilize() has been called.');

    return _nativeIrisApiEngineBinding.invokeMethod(
        _irisApiEnginePtr!, methodCall);
  }

  CallApiResult invokeMethod(IrisMethodCall methodCall) {
    return _invokeMethod(methodCall);
  }

  void dispose() {
    assert(_irisApiEnginePtr != null);

    _nativeIrisApiEngineBinding.destroyNativeApiEngine(_irisApiEnginePtr!);
    _irisApiEnginePtr = null;

    _irisEvent.dispose();

    _nativeIrisApiEngineBinding.destroyIrisEventHandler(_irisEventHandler!);
    _irisEventHandler = null;

    calloc.free(_irisCEventHandler!);
    _irisCEventHandler = null;
  }

  CallApiResult createNativeEventHandler(IrisMethodCall methodCall) {
    final eventHandlerIntPtr = _irisEventHandler!.address;
    final result = _invokeMethod(IrisMethodCall(
      methodCall.funcName,
      methodCall.params,
      rawBufferParams: [BufferParam(eventHandlerIntPtr, 1)],
    ));
    result.data['observerIntPtr'] = eventHandlerIntPtr;
    return result;
  }

  CallApiResult destroyNativeEventHandler(IrisMethodCall methodCall) {
    assert(methodCall.rawBufferParams != null);
    assert(methodCall.rawBufferParams!.length == 1);

    CallApiResult result;
    if (methodCall.funcName.isEmpty) {
      result = CallApiResult(irisReturnCode: 0, data: {'result': 0});
    } else {
      result = _invokeMethod(methodCall);
    }

    return result;
  }
}

class BufferParam {
  const BufferParam(this.intPtr, this.length);
  final int intPtr;
  final int length;
}

class ScopedEvent {
  const ScopedEvent({
    required this.scopedKey,
    required this.registerName,
    required this.unregisterName,
    // required this.params,
    required this.handler,
  });
  final TypedScopedKey scopedKey;
  final String registerName;
  final String unregisterName;
  // final String params;
  final EventLoopEventHandler handler;
}

abstract class IrisEventKey {
  const IrisEventKey({
    required this.registerName,
    required this.unregisterName,
  });
  final String registerName;
  final String unregisterName;

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is IrisEventKey &&
        other.registerName == registerName &&
        other.unregisterName == unregisterName;
  }

  @override
  int get hashCode => Object.hash(registerName, unregisterName);
}
