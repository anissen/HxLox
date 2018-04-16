package quirk;

import quirk.Expr;
import quirk.Stmt;
import quirk.TokenType;

class Parser {

  private var tokens:Array<Token>;
  private var current:Int = 0;
  private var reporter:ErrorReporter;

  public function new(tokens:Array<Token>, reporter:ErrorReporter) {
    this.tokens = tokens;
    this.reporter = reporter;
  }

  public function parse():Array<Stmt> {
    var stmts:Array<Stmt> = [];
    ignoreNewlines();
    while (!isAtEnd()) {
      stmts.push(declaration());
    }
    return stmts;
  }

  private function declaration(?meta:Array<Expr>):Stmt {
    try {
      if (match([ TokAt ])) return declaration(parseMeta());
      if (match([ TokVar ])) return varDeclaration(meta);
      if (match([ TokFun ])) return functionDeclaration('function', meta);
      if (match([ TokClass ])) return classDeclaration(meta);
      if (match([ TokImport ])) return importDeclaration(meta);
      if (match([ TokModule ])) return moduleDeclaration(meta);
      return statement();
    } catch (error:ParserError) {
      synchronize();
      return null;
    }
  }

  private function varDeclaration(?meta:Array<Expr>):Stmt {
    if (meta == null) meta = [];
    var name:Token = consume(TokIdentifier, "Expect variable name.");
    var initializer:Expr = null;
    if (match([ TokEqual ])) {
      initializer = expression();
    }
    expectEndOfStatement();
    // consume(TokSemicolon, "Expect ';' after value.");
    return new Stmt.Var(name, initializer, meta);
  }

  private function functionDef(kind:String, ?meta:Array<Expr>):Stmt {
    if (meta == null) meta = [];
    var name:Token;
    if (kind != 'lambda' || check(TokIdentifier)) {
      name = consume(TokIdentifier, 'Expect ${kind} name.');
    } else {
      name = new Token(TokIdentifier, '<annonymous>', '<annonymous>', previous().pos);
    }

    consume(TokLeftParen, 'Expect \'(\' after ${kind} name.');
    var params:Array<Token> = [];
    if (!check(TokRightParen)) {
      do {
        if (params.length >= 8) {
          error(peek(), "Cannot have more than 8 parameters.");
        }

        params.push(consume(TokIdentifier, 'Expect parameter name'));
      } while(match([ TokComma ]));
    }
    consume(TokRightParen, 'Expect \')\' after parameters');
    consume(TokLeftBrace, 'Expect \'{\' before ${kind} body');

    var body:Array<Stmt> = block();
    
    return new Stmt.Fun(name, params, body, meta);
  }

  private function functionDeclaration(kind:String, ?meta:Array<Expr>):Stmt {
    var def = functionDef(kind, meta);
    ignoreNewlines();
    return def;
  }

  private function classDeclaration(?meta:Array<Expr>):Stmt {
    if (meta == null) meta = [];
    var name = consume(TokIdentifier, "Expect a class name.");
    var superclass:Expr = null;

    if (match([ TokColon ])) {
      consume(TokIdentifier, "Expect superclass name.");
      superclass = new Expr.Variable(previous());
    }

    consume(TokLeftBrace, "Expect '{' before class body.");

    var methods:Array<Stmt.Fun> = [];
    var staticMethods:Array<Stmt.Fun> = [];
    ignoreNewlines();
    while(!check(TokRightBrace) && !isAtEnd()) {
      ignoreNewlines();
      var funMeta:Array<Expr> = match([ TokAt ]) ? parseMeta() : [];
      if (match([ TokStatic ])) {
        staticMethods.push(cast functionDeclaration('method', funMeta));
      } else {
        methods.push(cast functionDeclaration('method', funMeta));
      }
    }
    ignoreNewlines();
    consume(TokRightBrace, "Expect '}' after class body.");
    ignoreNewlines();

    return new Stmt.Class(name, superclass, methods, staticMethods, meta);
  }

  private function importDeclaration(?meta:Array<Expr>):Stmt {
    if (meta == null) meta = [];
    var path = parseList(TokDot, function ():Token {
      return consume(TokIdentifier, "Expect dot-seperated identifiers for 'import'");
    });
    var alias:Token = null;
    var items:Array<Token> = [];

    if (match([ TokAs ])) {
      ignoreNewlines();
      alias = consume(TokIdentifier, "Expect an identifier after `as`");
    } else if (match([ TokFor ])) {
      items = parseList(TokComma, function () {
        return consume(TokIdentifier, "Expect an identifier");
      });
    } else {
      error(previous(), "Expect a 'for' or an 'as' after an import path");
    }

    expectEndOfStatement();
    return new Stmt.Import(path, alias, items, meta);
  }

  private function moduleDeclaration(?meta:Array<Expr>):Stmt {
    if (meta == null) meta = [];
    var path = parseList(TokDot, function ():Token {
      return consume(TokIdentifier, "Expect dot-seperated identifiers for 'module'");
    });
    consume(TokFor, "Expect a 'for' after a module path");
    var items:Array<Token> = parseList(TokComma, function () {
      return consume(TokIdentifier, "Expect an identifier");
    });

    // if (check(TokLeftBrace)) {
    //   // inline module stuff here
    // } else {
      expectEndOfStatement();
    // }

    return cast new Stmt.Module(path, items, meta);
  }

  private function statement():Stmt {
    if (match([ TokIf ])) return ifStatement();
    if (match([ TokWhile ])) return whileStatement();
    if (match([ TokFor ])) return forStatement();
    if (match([ TokReturn ])) return returnStatement();
    if (match([ TokThrow ])) return throwStatement();
    if (match([ TokTry ])) return tryStatement();
    if (match([ TokLeftBrace ])) return blockStatement();
    return expressionStatement();
  }

  private function ifStatement():Stmt {
    consume(TokLeftParen, "Expect '(' after 'if'.");
    var condition:Expr = expression();
    consume(TokRightParen, "Expect ')' after if condition.");

    var thenBranch = statement();
    var elseBranch:Stmt = null;
    if (match([ TokElse ])) {
      elseBranch = statement();
    }

    return new Stmt.If(condition, thenBranch, elseBranch);
  }

  private function whileStatement():Stmt {
    consume(TokLeftParen, "Expect '(' after 'while'.");
    var condition = expression();
    consume(TokRightParen, "Expect ')' after 'while' condition.");
    var body = statement();

    return new Stmt.While(condition, body);
  }

  private function forStatement():Stmt {
    // consume(TokLeftParen, "Expect '(' after 'for'.");
    // var binding = consume(TokIdentifier, "Expect an identifier.");
    // ignoreNewlines();
    // consume(TokIn, "Expect 'in' after variable binding");
    // ignoreNewlines();
    // var iterator = expression();
    // consume(TokRightParen, "Expect ')' at the end of the `for` initializer.");
    // var body = statement();
    // return new Stmt.For(binding, iterator, body);

    // TODO:
    // Replace with `for (_ in _)`
    
    consume(TokLeftParen, "Expect '(' after 'for'.");
    
    var initializer:Stmt;
    if (match([ TokSemicolon ])) {
      initializer = null;
    } else if (match([ TokVar ])) {
      initializer = varDeclaration();
    } else {
      initializer = expressionStatement();
    }
    
    var condition:Expr = null;
    if (!check(TokSemicolon)) {
      condition = expression();
    }
    consume(TokSemicolon, "Expect ';' after loop condition.");
    ignoreNewlines();
    
    var increment:Expr = null;
    if (!check(TokRightParen)) {
      increment = expression();
    }
    consume(TokRightParen, "Expect ')' after loop condition.");
    ignoreNewlines();
    
    var body = statement();
    
    if (increment != null) {
      body = new Stmt.Block([
        body,
        new Stmt.Expression(increment)
      ]);
    }
    
    if (condition == null) {
      condition = new Expr.Literal(true);
    }
    body = new Stmt.While(condition, body);
    
    if (initializer != null) {
      body = new Stmt.Block([
        initializer,
        body
      ]);
    }
    
    return body;
  }

  private function returnStatement():Stmt {
    var keyword = previous();
    var value:Expr = null;
    if (!check(TokSemicolon) || !check(TokNewline)) {
      value = expression();
    }
    expectEndOfStatement();
    return new Stmt.Return(keyword, value);
  }

  private function expressionStatement():Stmt {
    var expr = expression();
    expectEndOfStatement();
    return new Stmt.Expression(expr);
  }

  private function throwStatement():Stmt {
    var value = expression();
    expectEndOfStatement();
    return new Stmt.Throw(previous(), value);
  }

  private function tryStatement():Stmt {
    ignoreNewlines();
    consume(TokLeftBrace, "Expect '{' after 'try'");
    ignoreNewlines();

    var body = blockStatement();

    ignoreNewlines();
    consume(TokCatch, "Expect 'catch' after try block");
    consume(TokLeftParen, "Expect '(' after 'catch'");
    var exception = consume(TokIdentifier, "Expect an identifier after 'catch'");
    consume (TokRightParen, "Expect ')' after identifier");
    consume(TokLeftBrace, "Expect { after 'catch'");

    ignoreNewlines();
    var caught = blockStatement();
    return new Stmt.Try(body, caught, exception);
  }

  private function block() {
    ignoreNewlines();
    var statements:Array<Stmt> = [];
    while (!check(TokRightBrace) && !isAtEnd()) {
      statements.push(declaration());
    }
    ignoreNewlines();
    consume(TokRightBrace, "Expect '}' after block.");
    // ignoreNewlines();
    return statements;
  }

  private function blockStatement() {
    var statements = block();
    ignoreNewlines();
    return new Stmt.Block(statements);
  }

  private function expression() {
    return assignment();
  }

  private function assignment() {
    var expr:Expr = or();

    if (match([ TokEqual ])) {
      var equals = previous();

      ignoreNewlines();
      var value = assignment();

      if (Std.is(expr, Expr.Variable)) {
        var name = (cast expr).name;
        return new Expr.Assign(name, value);
      } else if (Std.is(expr, Expr.Get)) {
        var get:Expr.Get = cast expr;
        return new Expr.Set(get.object, get.name, value);
      } else if (Std.is(expr, Expr.SubscriptGet)) {
        var get:Expr.SubscriptGet = cast expr;
        return new Expr.SubscriptSet(previous(), get.object, get.index, value);
      }

      error(equals, "Invalid assignment target.");
    }

    return expr;
  }

  private function or() {
    var expr:Expr = and();

    while (match([ TokBoolOr ])) {
      var operator = previous();
      var right = and();
      expr = new Expr.Logical(expr, operator, right);
    }

    return expr;
  }

  private function and() {
    var expr:Expr = equality();

    while (match([ TokBoolAnd ])) {
      var operator = previous();
      var right = equality();
      expr = new Expr.Logical(expr, operator, right);
    }

    return expr;
  }

  private function equality() {
    var expr:Expr = comparison();

    while(match([TokBangEqual, TokEqualEqual])) {
      var op = previous();
      var right = comparison();
      expr = new Expr.Binary(expr, op, right);
    }

    return expr;
  }

  private function comparison() {
    var expr = addition();

    while (match([ TokGreater, TokGreaterEqual, TokLess, TokLessEqual ])) {
      var op = previous();
      ignoreNewlines();
      var right = addition();
      expr = new Expr.Binary(expr, op, right);
    }

    return expr;
  }

  private function addition() {
    var expr = multiplication();

    while (match([ TokMinus, TokPlus ])) {
      var op = previous();
      ignoreNewlines();
      var right = multiplication();
      expr = new Expr.Binary(expr, op, right);
    }

    return expr;
  }

  private function multiplication() {
    var expr = unary();

    while (match([ TokSlash, TokStar ])) {
      var op = previous();
      ignoreNewlines();
      var right = unary();
      expr = new Expr.Binary(expr, op, right);
    }

    return expr;
  }

  private function unary() {
    if (match([ TokBang, TokMinus ])) {
      var op = previous();
      ignoreNewlines();
      var right = unary();
      return new Expr.Unary(op, right);
    }

    return call();
  }

  private function call():Expr {
    var expr:Expr = primary();

    while(true) {
      if (match([ TokLeftParen ])) {
        expr = finishCall(expr);
      } else if (match([ TokDot ])) {
        ignoreNewlines();
        var name = consume(TokIdentifier, "Expect property name after '.'.");
        expr = new Expr.Get(expr, name);
      } else if (match([ TokLeftBracket ])) {
        ignoreNewlines();
        var index = expression();
        ignoreNewlines();
        consume(TokRightBracket, "Expect ']' after expression");
        expr = new Expr.SubscriptGet(previous(), expr, index);
      // } else if (matchSequence([ TokNewline, TokDot ])) {
      //   // handle stuff like:
      //   //    foo
      //   //      .bar
      //   var name = consume(TokIdentifier, "Expect property name after '.'.");
      //   expr = new Expr.Get(expr, name);
      } else {
        break;
      }
    }

    return expr;
  }

  private function finishCall(callee:Expr):Expr {
    var arguments:Array<Expr> = [];

    if (!check(TokRightParen)) {
      do {
        if (arguments.length >= 8) { // limit of 8 for now
          error(peek(), "Cannot have more than 8 arguments.");
        }
        ignoreNewlines();
        arguments.push(expression());
      } while (match([ TokComma ]));
    }

    var paren = consume(TokRightParen, "Expect ')' after arguments.");

    return new Expr.Call(callee, paren, arguments);
  }

  private function primary():Expr {
    if (match([ TokFalse ])) return new Expr.Literal(false);
    if (match([ TokTrue ])) return new Expr.Literal(true);
    if (match([ TokNull ])) return new Expr.Literal(null);

    if (match([ TokNumber, TokString ])) {
      return new Expr.Literal(previous().literal);
    }

    if (match([ TokSuper ])) {
      var keyword = previous();
      consume(TokDot, "Expect '.' after 'super'.");
      ignoreNewlines();
      var method = consume(TokIdentifier, "Expect superclass method name.");
      return new Expr.Super(keyword, method);
    }

    if (match([ TokThis ])) {
      return new Expr.This(previous());
    }

    if (match([ TokIdentifier ])) {
      return new Expr.Variable(previous());
    }

    if (match([ TokLeftParen ])) {
      var expr = expression();
      consume(TokRightParen, "Expect ')' after expression.");
      return new Expr.Grouping(expr);
    }

    if (match([ TokLeftBracket ])) {
      return arrayLiteral();
    }

    if (match([ TokLeftBrace ])) {
      return objectOrLambda();
    }

    if (match([ TokFun ])) {
      return new Expr.Lambda(functionDef('lambda'));
    }

    throw error(peek(), 'Expect expression');
  }

  private function arrayLiteral():Expr {
    var values:Array<Expr> = [];
    if (!check(TokRightBracket)) {
      values = parseList(TokComma, expression);
    }
    ignoreNewlines(); // May be one after the last item in the list
    var end = consume(TokRightBracket, "Expect ']' after values.");
    return new Expr.ArrayLiteral(end, values);
  }

  private function objectOrLambda():Expr {
    ignoreNewlines();
    if (check(TokIdentifier) && checkNext(TokColon)) {
      return objectLiteral();
    }
    if (check(TokRightBrace)) {
      return objectLiteral();
    }
    return shortLambda();
  }

  private function shortLambda() {
    ignoreNewlines();
    var params:Array<Token> = [];
    if (match([ TokPipe ])) {
      if (!check(TokPipe)) {
        do {
          if (params.length >= 8) {
            error(peek(), "Cannot have more than 8 parameters.");
          }
          params.push(consume(TokIdentifier, 'Expect parameter name'));
        } while(match([ TokComma ]));
      }
      consume(TokPipe, 'Expect \'|\' after parameters');
    } else {
      params = [
        new Token(TokIdentifier, 'it', null, previous().pos)
      ];
    }
    var body:Array<Stmt> = block();
    return new Expr.Lambda(new Stmt.Fun(
      new Token(TokIdentifier, '<annonymous>', null, previous().pos),
      params,
      body,
      []
    ));
  }

  private function objectLiteral():Expr {
    var keys:Array<Token> = [];
    var values:Array<Expr> = [];

    if (!check(TokRightBrace)) {
      do {
        ignoreNewlines();
        keys.push(consume(TokIdentifier, "Expect identifiers for object keys"));
        consume(TokColon, "Expect colons after object keys");
        ignoreNewlines();
        values.push(expression());
      } while (match([ TokComma ]));
      ignoreNewlines();
    }

    var end = consume(TokRightBrace, "Expect '}' at the end of an object literal");

    return new Expr.ObjectLiteral(end, keys, values);
  }

  private function parseMeta():Array<Expr> {
    var meta:Array<Expr> = [];
    do {
      var name = consume(TokIdentifier, "Expected identifier after '@'");
      var items:Array<Expr> = [];
      if (match([ TokLeftParen ])) {
        if (!check(TokRightParen)) {
          items = parseList(TokComma, expression);
        }
        consume(TokRightParen, "Expected ')'");
      }
      ignoreNewlines();
      meta.push(new Expr.Metadata(name, items, null));
    } while (match([ TokAt ]));
    return meta;
  }

  private function match(types:Array<TokenType>):Bool {
    for (type in types) {
      if (check(type)) {
        advance();
        return true;
      }
    }
    return false;
  }

  private function matchSequence(types:Array<TokenType>):Bool {
    for (type in types) {
      if (!check(type)) {
        return false;
      }
    }
    // Only advance if all checks passed
    for (_ in types) {
      advance();
    }
    return true;
  }

  private function consume(type:TokenType, message:String) {
    if (check(type)) return advance();
    throw error(peek(), message);
  }

  private function check(type:TokenType):Bool {
    if (isAtEnd()) return false;
    return peek().type.equals(type);
  }

  private function checkNext(type:TokenType):Bool {
    if (isAtEnd()) return false;
    return peekNext().type.equals(type);
  }

  private function advance():Token {
    if (!isAtEnd()) current++;
    return previous();
  }

  private function isAtEnd() {
    return peek().type.equals(TokEof);
  }

  private function peek():Token {
    return tokens[current];
  }

  private function peekNext() {
    return tokens[current + 1];
  }

  private function previous():Token {
    return tokens[current - 1];
  }

  private function error(token:Token, message:String) {
    reporter.report(token.pos, token.lexeme, message);
    // HxLox.error(token, message);
    return new ParserError();
  }

  private function synchronize() {
    advance();
    while (!isAtEnd()) {
      if (previous().type.equals(TokSemicolon)) return;

      switch (peek().type) {
        case TokClass | TokFun | TokVar | TokFor | TokIf |
             TokWhile | TokReturn: return;
        default: advance();
      }
    }
  }

  private function parseList<T>(sep:TokenType, parser:Void->T):Array<T> {
    var items:Array<T> = [];
    do {
      ignoreNewlines();
      items.push(parser());
    } while (match([ sep ]) && !isAtEnd());
    return items;
  }

  private function expectEndOfStatement() {
    if (check(TokRightBrace)) {
      // special case -- allows stuff like '{ |a| a }'
      // We don't consume it here, as the parser needs to check for it.
      return true;
    }
    if (match([ TokNewline ])) {
      ignoreNewlines(); // consume any extras
      return true;
    }
    consume(TokSemicolon, "Expect newline or semicolon after statement");
    ignoreNewlines(); // consume any newlines
    return false;
  }

  private function ignoreNewlines() {
    while (!isAtEnd()) {
      if (!match([ TokNewline ])) {
        return;
      }
    }
  }

}

class ParserError {

  // todo

  public function new() {}

}
