import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_eval/src/eval/bridge/declaration/class.dart';
import 'package:dart_eval/src/eval/bridge/declaration/function.dart';
import 'package:dart_eval/src/eval/compiler/builtins.dart';
import 'package:dart_eval/src/eval/compiler/context.dart';
import 'package:dart_eval/src/eval/compiler/errors.dart';
import 'package:dart_eval/src/eval/compiler/type.dart';
import 'package:dart_eval/src/eval/compiler/variable.dart';
import 'package:dart_eval/src/eval/bridge/declaration.dart';
import 'package:dart_eval/src/eval/runtime/runtime.dart';

import '../util.dart';
import 'expression.dart';
import 'identifier.dart';

Variable compileMethodInvocation(CompilerContext ctx, MethodInvocation e) {
  Variable? L;
  if (e.target != null) {
    L = compileExpression(e.target!, ctx);
  }

  AlwaysReturnType? mReturnType;

  if (L != null) {
    final _dec = resolveInstanceMethod(ctx, L.type, e.methodName.name);

    Pair<List<Variable>, Map<String, Variable>> argsPair;

    if (_dec.isBridge) {
      final br = _dec.bridge!;
      argsPair = compileArgumentListWithBridge(ctx, e.argumentList, br.functionDescriptor, before: [L]);
    } else {
      final dec = _dec.declaration!;
      final fpl = dec.parameters?.parameters ?? <FormalParameter>[];

      argsPair = compileArgumentList(ctx, e.argumentList, L.type.file, fpl, dec, before: [L]);
    }

    final _args = argsPair.first;
    final _namedArgs = argsPair.second;

    final _argTypes = _args.map((e) => e.type).toList();
    final _namedArgTypes = _namedArgs.map((key, value) => MapEntry(key, value.type));

    final op = InvokeDynamic.make(L.scopeFrameOffset, e.methodName.name);
    ctx.pushOp(op, InvokeDynamic.len(op));

    mReturnType =
        AlwaysReturnType.fromInstanceMethodOrBuiltin(ctx, L.type, e.methodName.name, _argTypes, _namedArgTypes);
  } else {
    final method = compileIdentifier(e.methodName, ctx);
    if (method.methodOffset == null) {
      throw CompileError('Cannot call ${e.methodName.name} as it is not a valid method');
    }

    final offset = method.methodOffset!;
    var _dec = ctx.topLevelDeclarationsMap[offset.file]![e.methodName.name];
    if (_dec == null || (!_dec.isBridge && _dec.declaration! is ClassDeclaration)) {
      _dec = ctx.topLevelDeclarationsMap[offset.file]![e.methodName.name + '.']!;
    }

    if (_dec.isBridge) {
      throw CompileError('Bridge invocations are not supported');
    }

    final dec = _dec.declaration!;

    List<FormalParameter> fpl;
    if (dec is FunctionDeclaration) {
      fpl = dec.functionExpression.parameters?.parameters ?? <FormalParameter>[];
    } else if (dec is MethodDeclaration) {
      fpl = dec.parameters?.parameters ?? <FormalParameter>[];
    } else if (dec is ConstructorDeclaration) {
      fpl = dec.parameters.parameters;
    } else {
      throw CompileError('Invalid declaration type ${dec.runtimeType}');
    }

    final argsPair = compileArgumentList(ctx, e.argumentList, offset.file!, fpl, dec, before: L != null ? [L] : []);
    final _args = argsPair.first;
    final _namedArgs = argsPair.second;

    final _argTypes = _args.map((e) => e.type).toList();
    final _namedArgTypes = _namedArgs.map((key, value) => MapEntry(key, value.type));

    final loc = ctx.pushOp(Call.make(offset.offset ?? -1), Call.LEN);
    if (offset.offset == null) {
      ctx.offsetTracker.setOffset(loc, offset);
    }
    TypeRef? thisType;
    if (ctx.currentClass != null) {
      thisType = ctx.visibleTypes[ctx.library]![ctx.currentClass!.name.name]!;
    }
    mReturnType = method.methodReturnType?.toAlwaysReturnType(thisType, _argTypes, _namedArgTypes) ??
        AlwaysReturnType(EvalTypes.dynamicType, true);
  }

  ctx.pushOp(PushReturnValue.make(), PushReturnValue.LEN);
  final v = Variable.alloc(ctx,
      mReturnType?.type?.copyWith(boxed: L != null || !unboxedAcrossFunctionBoundaries.contains(mReturnType.type)) ??
          EvalTypes.dynamicType);

  return v;
}

DeclarationOrBridge<MethodDeclaration, BridgeMethodDeclaration> resolveInstanceMethod(
    CompilerContext ctx, TypeRef instanceType, String methodName) {
  if (instanceType.file < -1) {
    // Bridge
    final bridge = ctx.topLevelDeclarationsMap[instanceType.file]![instanceType.name]!.bridge! as BridgeClassDeclaration;
    return DeclarationOrBridge(bridge: bridge.methods[methodName]!);
  }
  final dec = ctx.instanceDeclarationsMap[instanceType.file]![instanceType.name]![methodName];

  if (dec != null) {
    return DeclarationOrBridge(declaration: dec as MethodDeclaration);
  } else {
    final $class = ctx.topLevelDeclarationsMap[instanceType.file]![instanceType.name] as ClassDeclaration;
    if ($class.extendsClause == null) {
      throw CompileError('Cannot resolve instance method');
    }
    final $supertype = ctx.visibleTypes[instanceType.file]![$class.extendsClause!.superclass2.name.name]!;
    return resolveInstanceMethod(ctx, $supertype, methodName);
  }
}

Pair<List<Variable>, Map<String, Variable>> compileArgumentList(CompilerContext ctx, ArgumentList argumentList,
    int decLibrary, List<FormalParameter> fpl, Declaration parameterHost,
    {List<Variable> before = const []}) {
  final _args = <Variable>[];
  final _push = <Variable>[];
  final _namedArgs = <String, Variable>{};

  final positional = <FormalParameter>[];
  final named = <String, FormalParameter>{};
  final namedExpr = <String, Expression>{};

  for (final param in fpl) {
    if (param.isNamed) {
      named[param.identifier!.name] = param;
    } else {
      positional.add(param);
    }
  }

  var i = 0;
  Variable? $null;

  for (final param in positional) {
    final arg = argumentList.arguments[i];
    if (arg is NamedExpression) {
      if (param.isRequired) {
        throw CompileError('Not enough positional arguments');
      } else {
        $null ??= BuiltinValue().push(ctx);
        _push.add($null);
      }
    } else {
      var paramType = EvalTypes.dynamicType;
      if (param is SimpleFormalParameter) {
        if (param.type != null) {
          paramType = TypeRef.fromAnnotation(ctx, decLibrary, param.type!);
        }
      } else if (param is FieldFormalParameter) {
        paramType = _resolveFieldFormalType(ctx, decLibrary, param, parameterHost);
      } else {
        throw CompileError('Unknown formal type ${param.runtimeType}');
      }

      var _arg = compileExpression(arg, ctx);
      if (parameterHost is MethodDeclaration) {
        _arg = _arg.boxIfNeeded(ctx);
      }

      if (!_arg.type.resolveTypeChain(ctx).isAssignableTo(paramType)) {
        throw CompileError(
            'Cannot assign argument of type ${_arg.type} to parameter "${param.identifier}" of type $paramType');
      }

      _args.add(_arg);
      _push.add(_arg);
    }

    i++;
  }

  for (final arg in argumentList.arguments) {
    if (arg is NamedExpression) {
      namedExpr[arg.name.label.name] = arg.expression;
    }
  }

  named.forEach((name, _param) {
    final param = (_param is DefaultFormalParameter ? _param.parameter : _param) as NormalFormalParameter;
    var paramType = EvalTypes.dynamicType;
    if (param is SimpleFormalParameter) {
      if (param.type != null) {
        paramType = TypeRef.fromAnnotation(ctx, decLibrary, param.type!);
      }
    } else if (param is FieldFormalParameter) {
      paramType = _resolveFieldFormalType(ctx, decLibrary, param, parameterHost);
    } else {
      throw CompileError('Unknown formal type ${param.runtimeType}');
    }
    if (namedExpr.containsKey(name)) {
      var _arg = compileExpression(namedExpr[name]!, ctx);
      if (parameterHost is MethodDeclaration) {
        _arg = _arg.boxIfNeeded(ctx);
      }
      if (!_arg.type.resolveTypeChain(ctx).isAssignableTo(paramType)) {
        throw CompileError(
            'Cannot assign argument of type ${_arg.type} to parameter "${param.identifier}" of type $paramType');
      }

      _push.add(_arg);

      _namedArgs[name] = _arg;
    } else {
      $null ??= BuiltinValue().push(ctx);
      _push.add($null!);
    }
  });

  for (final _arg in <Variable>[...before, ..._push]) {
    final argOp = PushArg.make(_arg.scopeFrameOffset);
    ctx.pushOp(argOp, PushArg.LEN);
  }

  return Pair(_args, _namedArgs);
}

Pair<List<Variable>, Map<String, Variable>> compileArgumentListWithBridge(
    CompilerContext ctx, ArgumentList argumentList, BridgeFunctionDescriptor function,
    {List<Variable> before = const []}) {
  final _args = <Variable>[];
  final _push = <Variable>[];
  final _namedArgs = <String, Variable>{};
  final namedExpr = <String, Expression>{};

  var i = 0;
  Variable? $null;

  for (final param in function.positionalParams) {
    final arg = argumentList.arguments[i];
    if (arg is NamedExpression) {
      if (!param.optional) {
        throw CompileError('Not enough positional arguments');
      } else {
        $null ??= BuiltinValue().push(ctx);
        _push.add($null);
      }
    } else {
      var paramType = TypeRef.fromBridgeAnnotation(ctx, param.typeAnnotation);

      final _arg = compileExpression(arg, ctx).boxIfNeeded(ctx);
      if (!_arg.type.resolveTypeChain(ctx).isAssignableTo(paramType)) {
        throw CompileError('Cannot assign argument of type ${_arg.type} to parameter of type $paramType');
      }
      _args.add(_arg);
      _push.add(_arg);
    }

    i++;
  }

  for (final arg in argumentList.arguments) {
    if (arg is NamedExpression) {
      namedExpr[arg.name.label.name] = arg.expression;
    }
  }

  function.namedParams.forEach((name, param) {
    var paramType = TypeRef.fromBridgeAnnotation(ctx, param.typeAnnotation);
    if (namedExpr.containsKey(name)) {
      final _arg = compileExpression(namedExpr[name]!, ctx).boxIfNeeded(ctx);
      if (!_arg.type.resolveTypeChain(ctx).isAssignableTo(paramType)) {
        throw CompileError('Cannot assign argument of type ${_arg.type} to parameter of type $paramType');
      }
      _push.add(_arg);
      _namedArgs[name] = _arg;
    } else {
      $null ??= BuiltinValue().push(ctx);
      _push.add($null!);
    }
  });

  for (final _arg in [...before, ..._push]) {
    final argOp = PushArg.make(_arg.scopeFrameOffset);
    ctx.pushOp(argOp, PushArg.LEN);
  }

  return Pair(_args, _namedArgs);
}

TypeRef _resolveFieldFormalType(
    CompilerContext ctx, int decLibrary, FieldFormalParameter param, Declaration parameterHost) {
  if (!(parameterHost is ConstructorDeclaration)) {
    throw CompileError('Field formals can only occur in constructors');
  }
  final $class = parameterHost.parent as ClassDeclaration;
  final field = ctx.instanceDeclarationsMap[decLibrary]![$class.name.name]![param.identifier.name]!;
  if (!(field is VariableDeclaration)) {
    throw CompileError('Resolved field is not a FieldDeclaration');
  }
  final vdl = field.parent as VariableDeclarationList;
  if (vdl.type != null) {
    return TypeRef.fromAnnotation(ctx, decLibrary, vdl.type!);
  }
  return EvalTypes.dynamicType;
}