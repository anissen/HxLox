package quirk.generator;

import quirk.Expr;
import quirk.Stmt;
import quirk.ExprVisitor;
import quirk.StmtVisitor;

using Lambda;
using StringTools;

class JsGenerator 
  implements Generator
  implements ExprVisitor<String> 
  implements StmtVisitor<String>
{

  private static var reserved:Array<String> = [
    'new', 'default', 'delete'
  ];
  private var target:Target;
  private var uid:Int = 0;
  private var indentLevel:Int = 0;
  private var append:Array<String> = [];
  private var moduleName:String = null;
  private var currentModule:Array<Token>;
  private var currentClass:String = null;

  public function new(target:Target, ?moduleName:String) {
    this.target = target;
    this.moduleName = moduleName;
    if (moduleName != null) {
      currentModule = moduleName
        .split('/')
        .map(function (l) return new quirk.Token(quirk.TokenType.TokIdentifier, l, l, { line: 0, offset: 0, file: moduleName }));
    }
  }

  public function generate(stmts:Array<Stmt>):String {
    var out:Array<String> = [];
    for (stmt in stmts) {
      var s = generateStmt(stmt);
      if (s != null && s != '') out.push(s);
    }
    return out.concat(this.append).join('\n');
  }
  
  private function generateStmt(stmt:Null<Stmt>):String {
    if (stmt == null) return '';
    return stmt.accept(this);
  }

  private function generateExpr(expr:Null<Expr>):String {
    if (expr == null) return '';
    return expr.accept(this);
  }

  public function visitBlockStmt(stmt:Stmt.Block):String {
    var out = getIndent() + '{\n';
    indent(); 
    out += stmt.statements.map(generateStmt).join('\n') + '\n';
    outdent();
    out += getIndent() + '}';
    return out;
  }

  public function visitExpressionStmt(stmt:Stmt.Expression):String {
    return getIndent() + generateExpr(stmt.expression) + ';';
  }

  public function visitIfStmt(stmt:Stmt.If):String {
    var out = getIndent() + 'if (' + generateExpr(stmt.condition) + ')\n' + generateStmt(stmt.thenBranch);
    if (stmt.elseBranch != null) {
      out += ' else ' + generateStmt(stmt.elseBranch);
    }
    return out;
  }

  public function visitReturnStmt(stmt:Stmt.Return):String {
    return getIndent() + (stmt.value == null
      ? 'return;'
      : 'return ' + generateExpr(stmt.value) + ';');
  }

  public function visitThrowStmt(stmt:Stmt.Throw):String {
    return getIndent() + 'throw ' + generateExpr(stmt.expr) + ';';
  }

  public function visitTryStmt(stmt:Stmt.Try):String {
    var out = getIndent() + 'try\n' + generateStmt(stmt.body);
    if (stmt.caught != null) {
      out += ' catch (' + stmt.exception.lexeme + ')\n' + generateStmt(stmt.caught);
    }
    return out;
  }

  public function visitWhileStmt(stmt:Stmt.While):String {
    return getIndent() + 'while (' + generateExpr(stmt.condition) + ') '
      + '\n' + generateStmt(stmt.body);
  }

  public function visitVarStmt(stmt:Stmt.Var):String {
    return getIndent() + 'var ' + safeVar(stmt.name) + ' = '
      + (stmt.initializer != null ? generateExpr(stmt.initializer) : 'null')
      + ';';
  }

  public function visitBinaryExpr(expr:Expr.Binary):String {
    return generateExpr(expr.left) + ' ' + expr.op.lexeme + ' ' + generateExpr(expr.right);
  }

  public function visitCallExpr(expr:Expr.Call):String {
    return generateExpr(expr.callee) + '(' + expr.args.map(generateExpr).join(', ')  + ')';
  }

  public function visitGetExpr(expr:Expr.Get):String {
    return generateExpr(expr.object) + '.' + expr.name.lexeme;
  }

  public function visitGroupingExpr(expr:Expr.Grouping):String {
    return '(' + generateExpr(expr.expression) + ')';
  }

  public function visitLiteralExpr(expr:Expr.Literal):String {
    return Std.is(expr.value, String)
      ? '"' + Std.string(expr.value)
        .replace('"', '\\"')
        .replace('\r', '')
        .replace('\n', '\\n') + '"'
      : expr.value;
  }

  public function visitLogicalExpr(expr:Expr.Logical):String {
    return generateExpr(expr.left) + expr.op.lexeme + generateExpr(expr.right);
  }

  public function visitSetExpr(expr:Expr.Set):String {
    return generateExpr(expr.object) + '.' + expr.name.lexeme + '=' + generateExpr(expr.value);
  }

  public function visitSubscriptGetExpr(expr:Expr.SubscriptGet):String {
    return generateExpr(expr.object) + '[' + generateExpr(expr.index) + ']';
  }

  public function visitSubscriptSetExpr(expr:Expr.SubscriptSet):String {
    return generateExpr(expr.object) + '[' + generateExpr(expr.index) + ']'
      + '=' + generateExpr(expr.value);
  }

  public function visitSuperExpr(expr:Expr.Super):String {
    return currentClass + '.__super.' + expr.method.lexeme + '.bind(this)'; // maybe???
  }

  public function visitThisExpr(expr:Expr.This):String {
    return 'this';
  }

  public function visitUnaryExpr(expr:Expr.Unary):String {
    return expr.op.lexeme + generateExpr(expr.right);
  }

  public function visitFunStmt(stmt:Stmt.Fun):String {
    return 'function ' + safeVar(stmt.name) + genParams(stmt.params) + '\n' 
      + genBlock(stmt.body);
  }

  public function visitClassStmt(stmt:Stmt.Class):String {
    var name = stmt.name.lexeme;
    currentClass = name;
    var fullName = moduleName == null
      ? name
      : moduleName.replace('/', '.') + '.' + name;
    var out = '';
    var constructors:Array<String> = [];
    var metaList:Map<String, Array<Expr>> = new Map();
    var propertyList:Map<String, { 
      name:String,
      target:String,
      ?getter:String,
      ?setter:String 
    }> = new Map();

    if (stmt.meta.length > 0) {
      metaList.set('__TYPE__', stmt.meta);
    }
    
    out += getIndent() + 'function ' + name + '() {};\n';

    if (stmt.superclass != null) {
      out += '__quirk.extend(' + name + ', ' + generateExpr(stmt.superclass) + ');\n';
      out += name + '.__super = ' + generateExpr(stmt.superclass) + '.prototype;\n'; 
    }

    out += name + '.__name = "' + fullName + '";\n';
    out += name + '.prototype.__name = "' + fullName + '";\n';

    out += stmt.staticMethods.map(function (method) {
      if (method.kind.equals(Stmt.FunKind.FunConstructor)) {
        constructors.push(method.name.lexeme);
      }
      return visitFieldStmt(name, method, propertyList, metaList);
    }).concat(stmt.methods.map(function (method) {
      return visitFieldStmt(name + '.prototype', method, propertyList, metaList);
    })).filter(function (v) return v != null).concat([ for (key in propertyList.keys()) {
      var prop = propertyList.get(key);
      var outProps = [];
      indent();
      if (prop.setter != null) {
        outProps.push(getIndent() + 'set: ' + prop.setter);
      }
      if (prop.getter != null){
        outProps.push(getIndent() + 'get: ' + prop.getter);
      }
      outdent();
      'Object.defineProperty(' + prop.target + ', "' + prop.name + '", {\n' 
        + outProps.join(',\n') + '\n' + getIndent() + '})';
    } ]).join(';\n') + ';\n';

    out += '__quirk.addClass("' + fullName + '", ' + name + ', [' + 
      constructors.map(function (c) return '"' + c + '"').join(', ')
    + ']);';

    out += '\n' + genMeta(name, metaList);
    currentClass = null;

    return out;
  }

  private function visitFieldStmt(
    target:String,
    method:Stmt.Fun,
    propertyList:Map<String, {
      target:String,
      name:String,
      ?getter:String,
      ?setter:String 
    }>,
    metaList:Map<String, Array<Expr>>
  ):String {
    if (method.meta.length > 0) {
      metaList.set(method.name.lexeme, method.meta);
    }
    var ident = target + '::' + method.name.lexeme;
    var initProp = function () {
      if (!propertyList.exists(ident)) {
        propertyList.set(ident, { 
          target: target,
          name: method.name.lexeme,
          setter: null, 
          getter: null 
        });
      }
    };
    // todo: maybe be a bit more explicit about properties.
    return switch method.kind {
      case Stmt.FunKind.FunGetter:
        initProp();
        indent();
        propertyList.get(ident).getter = visitFunStmt(method);
        outdent();
        null;
      case Stmt.FunKind.FunSetter:
        initProp();
        indent();
        propertyList.get(ident).setter = visitFunStmt(method);
        outdent();
        null;
      case Stmt.FunKind.FunConstructor:
        target + '.' + method.name.lexeme + ' = function ' + genParams(method.params) + '\n' 
          + getIndent() + '{\n' 
          + indent().getIndent() + 'var instance = new ' + target + '();\n'
          + getIndent() + 'instance.' + method.name.lexeme + genParams(method.params) + ';\n'
          + getIndent() + 'return instance;\n'
          + outdent().getIndent() + '}\n'
        + getIndent() + target + '.prototype.' + method.name.lexeme + ' = ' + visitFunStmt(method);
      default: 
        target + '.' + method.name.lexeme + ' = ' + visitFunStmt(method);
    }
  }

  public function visitImportStmt(stmt:Stmt.Import):String {
    // hardcoded behavior for now -- replace with something
    // better soon
    var npmPath:String = null;
    var isNpm:Bool = stmt.meta.find(function (m) {
      var meta:Expr.Metadata = cast m;
      if (meta.name.lexeme == 'npm') {
        if (meta.args.length > 0) {
          var arg = meta.args[0];
          if (Std.is(arg, Expr.Literal)) {
            npmPath = (cast arg:Expr.Literal).value;
          }
        }
        return true;
      }
      return false;
    }) != null;
    var dep = npmPath != null ? npmPath : target.resolveModule(stmt.path, isNpm ? null : currentModule);
    var file = target.resolveFile(stmt.path);

    target.addModuleDependency(moduleName, dep);
    if (!isNpm) { 
      target.addModule(file);
    }

    var tmp = tempVar('req');
    var out = [ 'var $tmp = require("$dep")' ];
    if (stmt.alias != null) {
      out.push('var ' + stmt.alias.lexeme + ' = ' + tmp);
    }
    return out.concat(stmt.imports.map(function (t) {
      return 'var ${t.lexeme} = ${tmp}.${t.lexeme}';
    })).join(';\n') + ';';
  }

  public function visitModuleStmt(stmt:Stmt.Module):String {
    var name = target.resolveModule(stmt.path);
    if (name == 'global') {
      moduleName = null;
      currentModule = [];
      append.push(stmt.exports.map(function (t) {
        return 'global.' + t.lexeme + ' = ' + t.lexeme + ';';
      }).join('\n'));
      return null;
    }
    moduleName = name;
    currentModule = stmt.path;
    append.push('module.exports = {' + stmt.exports.map(function (t) {
      return t.lexeme + ': ' + t.lexeme;
    }).join(', ') + '};');
    return null;
  }

  public function visitLambdaExpr(expr:Expr.Lambda):String {
    return visitFunStmt(cast expr.fun) + '.bind(this)';
  }

  public function visitVariableExpr(expr:Expr.Variable):String {
    return safeVar(expr.name);
  }

  public function visitMetadataExpr(expr:Expr.Metadata):String {
    return generateExpr(expr.expr); 
  }

  public function visitAssignExpr(expr:Expr.Assign):String {
    return expr.name.lexeme + ' = ' + generateExpr(expr.value);
  }

  public function visitArrayLiteralExpr(expr:Expr.ArrayLiteral):String {
    return '[' + expr.values.map(generateExpr).join(', ') + ']';
  }

  public function visitObjectLiteralExpr(expr:Expr.ObjectLiteral):String {
    if (expr.values.length == 0) {
      return '{}';
    }
    var out = '{\n';
    var pairs = [];
    indent();
    for (i in 0...expr.values.length) {
      pairs.push( getIndent() + expr.keys[i].lexeme + ': ' + generateExpr(expr.values[i]));
    }
    out += pairs.join(',\n') + '\n';
    outdent();
    return out + getIndent() + '}';
  }

  private function genBlock(stmts:Array<Stmt>) {
    var out = getIndent() + '{\n';
    indent();
    out += stmts.map(generateStmt).join('\n'); 
    outdent();
    return out + '\n' + getIndent() + '}';
  }

  private function genParams(params:Array<Token>) {
    return '(' + params.map(function (t) return t.lexeme).join(', ') + ')';
  }

  private function safeVar(tok:Token) {
    var name = tok.lexeme;
    if (reserved.indexOf(name) >= 0) {
      return '_' + name;
    }
    return name;
  }

  private function genMeta(target:String, data:Map<String, Array<Expr>>) {
    var out = '__quirk.addMeta(' + target + ', {';
    out += [ 
      for (key in data.keys()) 
        getIndent() + '"' + key + '": [' + data.get(key).map(getMetaEntry).join(', ') + ']' 
    ].join(', ');
    out += '});';
    return out;
  }

  private function getMetaEntry(expr:Expr) {
    var entry:Expr.Metadata = cast expr;
    return '{ name: "' + entry.name.lexeme + '", values: [' + entry.args.map(generateExpr).join(',') + '] }';
  }

  private function getIndent() {
    var out = '';
    for (i in 0...this.indentLevel) {
      out += '  ';
    }
    return out;
  }

  private function indent() {
    indentLevel++;
    return this;
  }

  private function outdent() {
    indentLevel--;
    if (indentLevel < 0) {
      indentLevel = 0;
    }
    return this;
  }

  private function tempVar(prefix:String = 'tmp') {
    return '__quirk_' + prefix + (uid++);
  }

}
