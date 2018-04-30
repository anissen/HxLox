package quirk.interpreter;

import quirk.Token;

using quirk.interpreter.Helper;

class Instance implements Object {

  @:isVar public var fields(default, never):Map<String, Dynamic> = new Map();
  private var cls:Class;

  public function new(cls:Class) {
    this.cls = cls;
  }

  public function get(interpreter:Interpreter, name:Token) {
    if (fields.exists(name.lexeme)) {
      return fields.get(name.lexeme);
    }

    var method = cls.findMethod(this, name.lexeme);
    if (method != null) return method; 

    method = cls.findMethod(this, name.getGetterName());
    if (method != null) return method.call(interpreter, []);
    
    throw new RuntimeError(name, "Undefined property '" + name.lexeme + "'.");
  }

  public function set(interpreter:Interpreter, name:Token, value:Dynamic) {
    var setter = cls.findMethod(this, name.getSetterName());
    if (setter != null) {
      setter.call(interpreter, [ value ]);
    } else {
      fields.set(name.lexeme, value);
    }
  }

  public function getClass() {
    return cls;
  }

  public function toString() {
    return '${this.cls.name} instance';
  }

}