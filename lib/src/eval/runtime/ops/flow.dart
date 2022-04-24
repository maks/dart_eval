part of '../runtime.dart';

/// Static call opcode that jumps to another location in the program and adds the prior location to the call stack.
class Call implements DbcOp {
  Call(Runtime runtime) : _offset = runtime._readInt32();

  Call.make(this._offset);

  final int _offset;

  static final int LEN = Dbc.BASE_OPLEN + Dbc.I32_LEN;

  @override
  void run(Runtime runtime) {
    runtime.callStack.add(runtime._prOffset);
    runtime._prOffset = _offset;
  }

  @override
  String toString() => 'Call (@$_offset)';
}

/// Push a new frame onto the stack, populated with any current args
class PushScope implements DbcOp {
  PushScope(Runtime runtime)
      : sourceFile = runtime._readInt32(),
        sourceOffset = runtime._readInt32(),
        frName = runtime._readString();

  PushScope.make(this.sourceFile, this.sourceOffset, this.frName);

  final int sourceFile;
  final int sourceOffset;
  final String frName;

  static int len(PushScope s) {
    return Dbc.BASE_OPLEN + Dbc.I32_LEN * 2 + Dbc.istr_len(s.frName);
  }

  @override
  void run(Runtime runtime) {
    final frame = List<Object?>.filled(255, null);
    runtime.stack.add(frame);
    runtime.frame = frame;
    runtime.frameOffsetStack.add(runtime.frameOffset);
    runtime.frameOffset = runtime.args.length;
    final args = runtime.args;
    for (var i = 0; i < args.length; i++) {
      frame[i] = args[i];
    }
    runtime.args = [];
  }

  @override
  String toString() => "PushScope (F$sourceFile:$sourceOffset, '$frName')";
}

/// Capture a reference to the previous stack frame (as a List) into the specified register of the current stack frame.
/// Typically used to implement closures
class PushCaptureScope implements DbcOp {
  PushCaptureScope(Runtime runtime);

  PushCaptureScope.make();

  static int LEN = Dbc.BASE_OPLEN;

  @override
  void run(Runtime runtime) {
    runtime.frame[runtime.frameOffset++] = runtime.stack[runtime.stack.length - 2];
  }

  @override
  String toString() => 'PushCaptureScope ()';
}

/// Pop the current frame off the stack
class PopScope implements DbcOp {
  PopScope(Runtime runtime);

  PopScope.make();

  static const int LEN = Dbc.BASE_OPLEN;

  @override
  void run(Runtime runtime) {
    runtime.stack.removeLast();
    if (runtime.stack.isNotEmpty) {
      runtime.frame = runtime.stack.last;
      runtime.frameOffset = runtime.frameOffsetStack.removeLast();
    }
  }

  @override
  String toString() => 'PopScope()';
}

/// Jump to constant program offset if [_location] is not null
class JumpIfNonNull implements DbcOp {
  JumpIfNonNull(Runtime runtime)
      : _location = runtime._readInt16(),
        _offset = runtime._readInt32();

  JumpIfNonNull.make(this._location, this._offset);

  final int _location;
  final int _offset;

  static const int LEN = Dbc.I16_LEN + Dbc.I32_LEN;

  // Conditional move
  @override
  void run(Runtime runtime) {
    if (runtime.frame[_location] != null) {
      runtime._prOffset = _offset;
    }
  }

  @override
  String toString() => 'JumpIfNonNull (@$_offset if L$_location != null)';
}

/// Jump to constant program offset if [_location] is false
class JumpIfFalse implements DbcOp {
  JumpIfFalse(Runtime runtime)
      : _location = runtime._readInt16(),
        _offset = runtime._readInt32();

  JumpIfFalse.make(this._location, this._offset);

  final int _location;
  final int _offset;

  static const int LEN = Dbc.I16_LEN + Dbc.I32_LEN;

  // Conditional move
  @override
  void run(Runtime runtime) {
    if (runtime.frame[_location] == false) {
      runtime._prOffset = _offset;
    }
  }

  @override
  String toString() => 'JumpIfFalse (@$_offset if L$_location == false)';
}

// Exit program
class Exit implements DbcOp {
  Exit(Runtime exec) : _location = exec._readInt16();

  Exit.make(this._location);

  final int _location;

  static const int LEN = Dbc.BASE_OPLEN + Dbc.I16_LEN;

  @override
  void run(Runtime runtime) {
    throw ProgramExit(runtime.frame[_location] as int);
  }

  @override
  String toString() => 'Exit (L$_location)';
}

/// Return from a function. This does several things:
/// 1. Sets the program's return value to the value at [_location], or null if [_location] is -1
/// 2. Pops the current frame off the stack, just like [PopScope]
/// 3. Pops the last offset from the call stack and jumps to it, unless it is -1 in which case [Exit] is mimicked
class Return implements DbcOp {
  Return(Runtime runtime) : _location = runtime._readInt16();

  Return.make(this._location);

  final int _location;

  static const int LEN = Dbc.BASE_OPLEN + Dbc.I16_LEN;

  @override
  void run(Runtime runtime) {
    if (_location == -1) {
      runtime.returnValue = null;
    } else {
      runtime.returnValue = runtime.frame[_location];
    }

    runtime.stack.removeLast();
    if (runtime.stack.isNotEmpty) {
      runtime.frame = runtime.stack.last;
      runtime.frameOffset = runtime.frameOffsetStack.removeLast();
    }

    final prOffset = runtime.callStack.removeLast();
    if (prOffset == -1) {
      throw ProgramExit(0);
    }
    runtime._prOffset = prOffset;
  }

  @override
  String toString() => 'Return (L$_location)';
}

// Jump to constant program offset
class JumpConstant implements DbcOp {
  JumpConstant(Runtime runtime) : _offset = runtime._readInt32();

  JumpConstant.make(this._offset);

  static const int LEN = Dbc.BASE_OPLEN + Dbc.I32_LEN;

  final int _offset;

  @override
  void run(Runtime runtime) {
    runtime._prOffset = _offset;
  }

  @override
  String toString() => 'JumpConstant (@$_offset)';
}

class PushFunctionPtr implements DbcOp {
  PushFunctionPtr(Runtime runtime) : _offset = runtime._readInt32();

  PushFunctionPtr.make(this._offset);

  static const int LEN = Dbc.BASE_OPLEN + Dbc.I32_LEN;

  final int _offset;

  @override
  void run(Runtime runtime) {
    final args = runtime.args;
    final pAT = runtime.constantPool[args[1] as int] as List;
    final posArgTypes = [for (final json in pAT) RuntimeType.fromJson(json)];
    final snAT = runtime.constantPool[args[3] as int] as List;
    final sortedNamedArgTypes = [
      for (final json in snAT) RuntimeType.fromJson(json)
    ];

    runtime.frame[runtime.frameOffset++] = EvalFunctionPtr(
        null,
        _offset,
        args[0] as int,
        posArgTypes,
        (runtime.constantPool[args[2] as int] as List).cast(),
        sortedNamedArgTypes);

    runtime.args = [];
  }

  @override
  String toString() => 'PushFunctionPtr (@$_offset)';
}
