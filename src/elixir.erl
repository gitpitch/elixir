-module(elixir).
-export([boot/0, eval/1, eval/2, parse/2]).
-include("elixir.hrl").
-import(lists, [umerge/2, umerge3/3]).

% Boot up Elixir setting up tables and loading main files.
boot() ->
  code:ensure_loaded(elixir_object_methods),
  load_core_classes().

% Load core elixir classes
load_core_classes() ->
  Dirname = filename:dirname(?FILE),
  Basepath = filename:join([Dirname, "..", "lib"]),
  Loader = fun(Class) -> load_file(filename:join(Basepath, Class)) end,
  lists:foreach(Loader, [
    'object.ex',
    'module.ex',
    'numeric.ex',
    'integer.ex',
    'float.ex'
  ]).

% Loads a given file
% TODO Binding here should pass self = Object
load_file(Filepath) ->
  {ok, Bin} = file:read_file(Filepath),
  eval(binary_to_list(Bin)).

% Evaluates a string
eval(String) -> eval(String, []).

eval(String, Binding) ->
  {value, Value, NewBinding} = erl_eval:exprs(parse(String, Binding), Binding),
  {Value, NewBinding}.

% Parse string and transform tree to Erlang Abstract Form format
parse(String, Binding) ->
	{ok, Tokens, _} = elixir_lexer:string(String),
	{ok, Forms} = elixir_parser:parse(Tokens),
	Vars = lists:usort([self|proplists:get_keys(Binding)]),
	{NewForms, _ } = transform_tree(Forms, Vars, {false,[]}),
	NewForms.

% Transform the given tree Forms.
%
% V is a list of variables that were bound (used for arranging
% implicit self) and S is the scope. The scope is a tuple with
% two elements. The first is a boolean that says if we are in a
% scope where new variables can be defined (i.e. the left side
% of a match or function clauses) and the second the nested
% module name.
transform_tree(Forms, V, S) ->
  Transform = fun(X, Acc) -> transform(X, Acc, S) end,
  lists:mapfoldl(Transform, V, Forms).

% A transformation receives a node with a variables list (V),
% a scope (S) and transforms it to Erlang Abstract Form.

% Represents a method call. The arguments need to be packed into
% an array before sending it to dispatch (which has fixed arity).
%
% = Variables
%
% Both the prefix of the function as the arguments can declare new variables:
%
%   (a = 1).+(b = 2)
%
transform({method_call, Line, Name, Args, Expr}, V, S) ->
  { TArgs, VA } = transform({list, Line, Args}, V, S),
  { TExpr, VE } = transform(Expr, V, S),
  { ?ELIXIR_WRAP_CALL(Line, elixir_dispatch, dispatch, [TExpr, {atom, Line, Name}, TArgs]), umerge3(V,VA,VE) };

% Reference to a constant (that should then be loaded).
%
% = Variables
%
% It has no affect on variables scope.
transform({constant, Line, Name}, V, S) ->
  { ?ELIXIR_WRAP_CALL(Line, elixir_constants, lookup, [{atom, Line, Name}]), V };

% Handle function calls.
%
% = Variables
%
% Both the left and right side can contain variable declarations, as below:
%
%   (a = -> (x) x + 2)(b = 1)
%
% So we need to take both into account.
%
% Also, there are a few cases where a function may be ambigous with a method call:
%
%    module Foo
%      def bar; 1; end
%      def baz; bar(); end
%    end
%
% This is parsed as a function call but is properly disambiguated to a method
% call in this method.
transform({fun_call, Line, Var, Args }, V, S) ->
  case Var of
    { identifier, _, Name } -> Method = not lists:member(Name, V);
    Name -> Method = false
  end,

  case Method of
    true -> transform({method_call, Line, Name, Args, {var, Line, self}}, V, S);
    false ->
      { TArgs, VA } = transform_tree(Args, V, S),
      { TVar, VV }  = transform(Var, V, S),
      { {call, Line, TVar, TArgs}, umerge3(V, VA, VV) }
  end;

% Handle match declarations.
%
% = Variables
%
% Both the left and right side can contain variable declarations, as below:
%
%   a = (b = 1)
%
% So we need to take both into account.
transform({match, Line, Left, Right}, V, S) ->
  { Var, Mod } = S,
  { TLeft, VL } = transform(Left, V, { true, Mod }),
  { TRight, VR } = transform(Right, V, S),
  { {match, Line, TLeft, TRight }, umerge3(V, VL, VR) };

% Handle tuple declarations.
%
% = Variables
%
% Each expression in the tuple can contain a match expression.
% Variables defined inside these expressions needs to be added to the var list.
transform({tuple, Line, Exprs }, V, S) ->
  { TExprs, VE } = transform_tree(Exprs, V, S),
  { {tuple, Line, TExprs}, umerge(V, VE) };

% Handle list declarations.
%
% = Variables
%
% Each expression in the list can contain a match expression.
% Variables defined inside these expressions needs to be added to the var list.
transform({list, Line, Exprs }, V, S) ->
  { TExprs, VE } = transform_tree(Exprs, V, S),
  Transform = fun(Expr, Acc) -> {cons, Line, Expr, Acc} end,
  { lists:foldr(Transform, {nil, Line}, TExprs), umerge(V, VE) };

% Handle binary operations.
%
% = Variables
%
% The Left and Right values of the binary operation can be a match expression.
% Variables defined inside these expressions needs to be added to the list.
transform({binary_op, Line, Op, Left, Right}, V, S) ->
  { TLeft, VL } = transform(Left, V, S),
  { TRight, VR } = transform(Right, V, S),
  Args = { cons, Line, TRight, {nil, Line} },
  { ?ELIXIR_WRAP_CALL(Line, elixir_dispatch, dispatch, [TLeft, {atom, Line, Op}, Args]), umerge3(V, VL, VR) };

% Handle unary operations.
%
% = Variables
%
% The target (Right) of the unary operation can be a match expression.
% Variables defined inside these expressions needs to be added to the list.
transform({unary_op, Line, Op, Right}, V, S) ->
  { TRight, V1} = transform(Right, V, S),
  { { op, Line, Op, TRight }, umerge(V, V1) };

% Handle functions declarations. They preserve the current binding.
%
% = Variables
%
% Variables defined inside functions do not leak to the outer scope
% but variables previously defined affect the current function.
transform({'fun', Line, {clauses, Clauses}}, V, S) ->
  TClauses = [transform(Clause, V, S) || Clause <- Clauses],
  { { 'fun', Line, {clauses, TClauses} }, V };

% Handle function clauses.
%
% = Variables
%
% Variables declared in args do affect the exprs and should be taken
% into account. Clauses do not return variables list as second argument
% because variables in one clause should not affect the other.
transform({clause, Line, Args, Guards, Exprs}, V, S) ->
  { Var, Mod } = S,
  { TArgs, V1 } = transform_tree(Args, V, { true, Mod }),
  { TExprs, _ } = transform_tree(Exprs, umerge(V, V1), S),
  { clause, Line, TArgs, Guards, TExprs };

% Handles erlang function calls in the following format:
%
%   erl.lists.mapfoldr()
%
% = Variables
%
% Variables can be set inside the args hash, so they need
% to be taken into account on the variables list.
transform({erlang_call, Line, Prefix, Suffix, Args}, V, S) ->
  { TArgs, V1 } = transform_tree(Args, V, S),
  { ?ELIXIR_WRAP_CALL(Line, Prefix, Suffix, TArgs), umerge(V, V1) };

% Method definitions are never executed by Elixir runtime. Their
% abstract form is stored into an ETS table and is just added to
% an Erlang module when they are compiled.
%
% = Variables
%
% Variables are handled in each function clause.
%
% TODO Test that a method declaration outside a module raises an error.
transform({method, Line, Name, Arity, Clauses}, V, S) ->
  {Var, Module} = S,
  TClauses = [pack_method_clause(Clause, V, S) || Clause <- Clauses],
  Method = {function, Line, Name, Arity + 1, TClauses},
  { elixir_object:wrap_method_definition(Module, Line, Method), V };

% Handles identifiers, i.e. method calls or variable calls, allowing
% implicit self.
%
% = Variables
%
% If the scope has true for variables, it means new variables can be
% defined. In such cases, variables are added to the list if they don't
% exist yet. If we cannot define a variable and it does not belong to
% the list, make it a method call.
transform({identifier, Line, Name}, V, S) ->
  { Var, Mod } = S,
  case { Var, lists:member(Name, V) } of
    { _, true }      -> { {var, Line, Name}, V };
    { true, false }  -> { {var, Line, Name}, lists:sort([Name|V]) };
    { false, false } -> transform({method_call, Line, Name, [], {var, Line, self}}, V, S)
  end;

% Handle module/object declarations.
%
% = Variables
%
% Objects do not share binding with the previous context, so
% previous variable declarations do not affect a module and
% variables declared in a module do not leak outside its
% context. The only variable available in the module by default
% is self.
transform({Decl, Line, Name, Exprs}, V, S) when Decl == object; Decl == module ->
  {Var, Current} = S,
  NewName = elixir_object:scope_for(Current, Name),
  Scope = { Var, NewName },
  { TExprs, _ } = transform_tree(Exprs, [self], Scope),
  { elixir_object:transform(Decl, Line, NewName, TExprs), V };

% Match all other expressions.
% TODO Expand instead of catch all.
transform(Expr, V, S) -> { Expr, V }.

% Pack method clause in a format that receives Elixir metadata
% as first argument (like self) and annotates __current__ with
% the current module name (for super).
%
% = Variables
%
% It does not accummulate variables because variables in one
% clause do not affect the other. Each clause starts with an
% empty variable set as there is no binding.
pack_method_clause({clause, Line, Args, Guards, Exprs}, V, S) ->
  Clause = {clause, Line, [{var, Line, self}|Args], Guards, Exprs},
  transform(Clause, [self], S).