module P = Parser
open Helper
open Printf

type environment =
  { symbols: (string, P.ast) Hashmap.t
  ; parent: environment option
  ; freevars: (string * string) list ref }

let filter_after_map f lst =
  List.map (function Some x -> x | None -> failwith "invalid op")
  @@ List.filter (function Some x -> true | None -> false)
  @@ List.map f lst

let rec list_unique lst =
  let set = Hashtbl.create @@ List.length lst in
  let rec aux res = function
    | [] -> res
    | x :: xs ->
        if Hashtbl.mem set x then aux res xs
        else (
          Hashtbl.add set x () ;
          aux (x :: res) xs )
  in
  aux [] lst

let add_symbols_in_pattern symbols ptn =
  integrate symbols @@ hashmap_of_list
  @@ List.map (fun n -> (n, P.Var (make_id n)))
  @@ P.varnames_in_pattern ptn

let add_symbols_in_patterns symbols ptns =
  integrate symbols @@ hashmap_of_list
  @@ List.map (fun n -> (n, P.Var (make_id n)))
  @@ List.flatten
  @@ List.map P.varnames_in_pattern ptns

type type_toplevel =
  { mutable letfuncs: P.ast list
  ; mutable strings: P.ast list
  ; mutable typedefs: P.typedef list
  ; mutable exps_list: string list
  ; ctors_type: (string, string) Hashtbl.t
  ; exps: (string, string) Hashtbl.t
  ; records: (string, string) Hashtbl.t
  ; records_fields: (string, string list) Hashtbl.t
  ; mutable modulename: string list
  ; (* TODO: opened_modulename should be in type environment
   * rather than type type_toplevel, because
   * functions, exceptions, types, and etc. in the opened module
   * mask previously defined ones with the same names.
   * For example, the current implementation doesn't allow the following code:
   *     module ABC = struct let f () = 5 end ;;
   *     let f () = 3 ;;
   *     open ABC;;
   *     test (f ()) 5 ;; (* expect 5 but will get 3 *)
   *)
    mutable opened_modulename: string list
  ; mutable modules: (string, string) Hashtbl.t }

(* Used in analysis of P.LetAnd *)
exception Should_be_closure

exception LetDef of P.ast list * environment

let analyze asts =
  let toplevel =
    { letfuncs= []
    ; strings= []
    ; typedefs= []
    ; exps_list= []
    ; ctors_type= Hashtbl.create 16
    ; exps= Hashtbl.create 16
    ; records= Hashtbl.create 16
    ; records_fields= Hashtbl.create 16
    ; modulename= []
    ; opened_modulename= ["Stdlib."]
    ; modules= Hashtbl.create 16 }
  in
  let with_modulename name =
    String.concat "." @@ List.rev @@ (name :: toplevel.modulename)
  in
  let exprs2expr = function
    | [] -> P.Nope
    | [expr] -> expr
    | exprs -> P.ExprSeq exprs
  in
  let get_modulename_prefix modulename =
    let buf = Buffer.create 128 in
    List.iter (fun modname ->
        Buffer.add_string buf modname ;
        Buffer.add_char buf '.' )
    @@ List.rev @@ modulename ;
    Buffer.contents buf
  in
  let find_with_modulename find name =
    let analyze prefix components =
      let rec aux prefix = function
        | [name] ->
            let key = prefix ^ name in
            (key, find key)
        | x :: xs -> aux (Hashtbl.find toplevel.modules @@ prefix ^ x ^ ".") xs
        | [] -> failwith "[FATAL]"
      in
      aux prefix components
    in
    let components =
      if name.[0] = '.' then [name] else String.split_on_char '.' name
    in
    try analyze "" components with Not_found -> (
      try
        let rec aux modulename =
          let prefix = get_modulename_prefix modulename in
          try analyze prefix components with Not_found -> (
            match modulename with _ :: xs -> aux xs | [] -> raise Not_found )
        in
        aux toplevel.modulename
      with Not_found ->
        let rec aux = function
          | prefix :: opened_modulename -> (
            try analyze prefix components with Not_found ->
              aux opened_modulename )
          | [] -> raise Not_found
        in
        aux toplevel.opened_modulename )
  in
  let hashtbl_find_with_modulename hashtbl name =
    find_with_modulename (fun x -> Hashtbl.find hashtbl x) name
  in
  let hashmap_find_with_modulename name hashmap =
    let _, res = find_with_modulename (fun x -> Hashmap.find x hashmap) name in
    res
  in
  let find_symbol env name =
    let rec aux depth env =
      try (depth, hashmap_find_with_modulename name env.symbols)
      with Not_found -> (
        match env.parent with
        | Some parent -> aux (depth + 1) parent
        | None ->
            failwith (sprintf "not found in analysis (find_symbol): %s" name) )
    in
    aux 0 env
  in
  let rec aux_ptn env ptn =
    match ptn with
    | P.IntValue _ | P.CharValue _ | P.UnitValue | P.EmptyList | P.PtnRange _
      ->
        ptn
    | P.StringValue _ ->
        toplevel.strings <- ptn :: toplevel.strings ;
        ptn
    | P.TupleValue values ->
        P.TupleValue (List.map (fun x -> aux_ptn env x) values)
    | P.Cons (car, cdr) -> P.Cons (aux_ptn env car, aux_ptn env cdr)
    | P.Var name -> (
        let find_symbol env name =
          let rec aux depth env =
            try (depth, Hashmap.find name env.symbols) with Not_found -> (
              match env.parent with
              | Some parent -> aux (depth + 1) parent
              | None ->
                  failwith
                    (sprintf "not found in analysis (find_symbol): %s" name) )
          in
          aux 0 env
        in
        match find_symbol env name with
        | 0, sym -> sym
        | _ -> failwith "[FATAL] variable not found in pattern analysis" )
    | P.PtnAlias (ptn, (P.Var _ as var)) ->
        P.PtnAlias (aux_ptn env ptn, aux_ptn env var)
    | P.PtnOr (lhs, rhs) -> P.PtnOr (aux_ptn env lhs, aux_ptn env rhs)
    | P.CtorApp (None, ctorname, arg) ->
        let arg =
          match arg with Some arg -> Some (aux_ptn env arg) | _ -> None
        in
        let ctorname_or_expname, typename =
          try hashtbl_find_with_modulename toplevel.ctors_type ctorname
          with Not_found -> hashtbl_find_with_modulename toplevel.exps ctorname
        in
        P.CtorApp (Some typename, ctorname_or_expname, arg)
    | _ -> failwith "unexpected pattern"
  in
  let rec analyze_pattern_match_cases env cases =
    List.map
      (fun (ptn, whn, ast) ->
        let env' =
          {env with symbols= add_symbols_in_pattern env.symbols ptn}
        in
        ( aux_ptn env' ptn
        , (match whn with Some expr -> Some (aux env' expr) | None -> None)
        , aux env' ast ) )
      cases
  and aux env ast =
    match ast with
    | P.IntValue _ | P.CharValue _ | P.UnitValue | P.EmptyList -> ast
    | P.StringValue _ ->
        toplevel.strings <- ast :: toplevel.strings ;
        ast
    | P.TupleValue values ->
        P.TupleValue (List.map (fun x -> aux env x) values)
    | P.ArrayValue values ->
        P.ArrayValue (List.map (fun x -> aux env x) values)
    | P.RecordValue (None, fields) ->
        let key_fieldname, _ = List.hd fields in
        let full_key_fieldname, typename =
          hashtbl_find_with_modulename toplevel.records key_fieldname
        in
        let name_prefix =
          ( String.sub full_key_fieldname 0
          @@ String.rindex full_key_fieldname '.' )
          ^ "."
        in
        P.RecordValue
          ( Some typename
          , List.map
              (fun (name, ast) -> (name_prefix ^ name, aux env ast))
              fields )
    | P.RecordValueWith (None, base, fields, None) ->
        let key_fieldname, _ = List.hd fields in
        let full_key_fieldname, typename =
          hashtbl_find_with_modulename toplevel.records key_fieldname
        in
        let name_prefix =
          ( String.sub full_key_fieldname 0
          @@ String.rindex full_key_fieldname '.' )
          ^ "."
        in
        let fields =
          hashmap_of_list
          @@ List.map
               (fun (fieldname, v) -> (name_prefix ^ fieldname, aux env v))
               fields
        in
        let fieldnames = Hashtbl.find toplevel.records_fields typename in
        let comp_fieldnames =
          List.filter
            (fun fieldname -> not @@ Hashmap.mem fieldname fields)
            fieldnames
        in
        P.RecordValueWith
          (Some typename, aux env base, fields, Some comp_fieldnames)
    | P.RecordDotAccess (None, ast, fieldname) ->
        let fieldname, typename =
          hashtbl_find_with_modulename toplevel.records fieldname
        in
        P.RecordDotAccess (Some typename, aux env ast, fieldname)
    | P.Cons (car, cdr) -> P.Cons (aux env car, aux env cdr)
    | P.Add (lhs, rhs) -> P.Add (aux env lhs, aux env rhs)
    | P.Sub (lhs, rhs) -> P.Sub (aux env lhs, aux env rhs)
    | P.Mul (lhs, rhs) -> P.Mul (aux env lhs, aux env rhs)
    | P.Div (lhs, rhs) -> P.Div (aux env lhs, aux env rhs)
    | P.Rem (lhs, rhs) -> P.Rem (aux env lhs, aux env rhs)
    | P.LogicalLeftShift (lhs, rhs) ->
        P.LogicalLeftShift (aux env lhs, aux env rhs)
    | P.LogicalRightShift (lhs, rhs) ->
        P.LogicalRightShift (aux env lhs, aux env rhs)
    | P.ArithmeticRightShift (lhs, rhs) ->
        P.ArithmeticRightShift (aux env lhs, aux env rhs)
    | P.BitwiseAnd (lhs, rhs) -> P.BitwiseAnd (aux env lhs, aux env rhs)
    | P.BitwiseOr (lhs, rhs) -> P.BitwiseOr (aux env lhs, aux env rhs)
    | P.StringConcat (lhs, rhs) -> P.StringConcat (aux env lhs, aux env rhs)
    | P.ListConcat (lhs, rhs) -> P.ListConcat (aux env lhs, aux env rhs)
    | P.RefAssign (lhs, rhs) -> P.RefAssign (aux env lhs, aux env rhs)
    | P.RecordAssign (None, lhs, fieldname, rhs) ->
        let fieldname, typename =
          hashtbl_find_with_modulename toplevel.records fieldname
        in
        P.RecordAssign (Some typename, aux env lhs, fieldname, aux env rhs)
    | P.Deref ast -> P.Deref (aux env ast)
    | P.Negate ast -> P.Negate (aux env ast)
    | P.Positate ast -> P.Positate (aux env ast)
    | P.StructEqual (lhs, rhs) -> P.StructEqual (aux env lhs, aux env rhs)
    | P.StructInequal (lhs, rhs) -> P.StructInequal (aux env lhs, aux env rhs)
    | P.LessThan (lhs, rhs) -> P.LessThan (aux env lhs, aux env rhs)
    | P.LessThanEqual (lhs, rhs) -> P.LessThanEqual (aux env lhs, aux env rhs)
    | P.LogicalAnd (lhs, rhs) -> P.LogicalAnd (aux env lhs, aux env rhs)
    | P.LogicalOr (lhs, rhs) -> P.LogicalOr (aux env lhs, aux env rhs)
    | P.IfThenElse (cond, then_body, Some else_body) ->
        P.IfThenElse (aux env cond, aux env then_body, Some (aux env else_body))
    | P.IfThenElse (cond, then_body, None) ->
        P.IfThenElse (aux env cond, aux env then_body, None)
    | P.ExprSeq exprs -> P.ExprSeq (List.map (fun x -> aux env x) exprs)
    | P.Lambda (args, body) ->
        let funcname = ".lambda" in
        aux env
        @@ P.LetAnd
             (false, [(P.Var funcname :: args, body)], Some (P.Var funcname))
    | P.StringGet (str, idx) ->
        (* a.[b] returns a b-th character of a string a.
         * Therefore, convert it to String.get call *)
        aux env @@ P.AppCls (P.Var "String.get", [str; idx])
    | P.StringSet (str, idx, ast) ->
        aux env @@ P.AppCls (P.Var "String.set", [str; idx; ast])
    | P.ArrayGet (ary, idx) ->
        (* a.(b) returns b-th item of array a.
         * Therefore, convert it to Array.get call *)
        aux env @@ P.AppCls (P.Var "Array.get", [ary; idx])
    | P.TryWith (cond, cases) ->
        P.TryWith (aux env cond, analyze_pattern_match_cases env cases)
    | P.MatchWith (cond, cases) ->
        P.MatchWith (aux env cond, analyze_pattern_match_cases env cases)
    | P.Var name -> (
      match find_symbol env name with
      | 0, (P.Var _ as sym) -> sym
      | _, P.FuncVar (gen_funcname, 0) -> P.AppDir (gen_funcname, [])
      | 0, P.FuncVar (funcname, nargs) ->
          (* When P.FuncVar is processed here, P.AppDir will not be applied to this P.FuncVar.
           * Therefore the returned value should be closured in case
           * P.AppCls is applied to this value. *)
          P.MakeCls (funcname, nargs, [])
      | _, (P.Var id as sym) ->
          env.freevars := (name, id) :: !(env.freevars) ;
          sym
      | _ -> failwith @@ sprintf "not found variable in analysis: %s" name )
    | P.CtorApp (None, ctorname, None) ->
        let ctorname_or_expname, typename =
          try hashtbl_find_with_modulename toplevel.ctors_type ctorname
          with Not_found -> hashtbl_find_with_modulename toplevel.exps ctorname
        in
        P.CtorApp (Some typename, ctorname_or_expname, None)
    | P.TypeAnd entries ->
        toplevel.typedefs
        <- List.rev_append toplevel.typedefs
           @@ List.map
                (function
                  | P.DefTypeAlias (type_param, typename, typ) ->
                      let typename = with_modulename typename in
                      P.DefTypeAlias (type_param, typename, typ)
                  | P.DefVariant (type_param, typename, ctornames) ->
                      let typename = with_modulename typename in
                      let ctornames =
                        List.map
                          (fun (ctorname, typexpr) ->
                            (with_modulename ctorname, typexpr) )
                          ctornames
                      in
                      List.iter
                        (fun (ctorname, _) ->
                          Hashtbl.add toplevel.ctors_type ctorname typename )
                        ctornames ;
                      P.DefVariant (type_param, typename, ctornames)
                  | P.DefRecord (typename, fields) ->
                      let typename = with_modulename typename in
                      let fields =
                        List.map
                          (fun (fieldname, typexpr) ->
                            (with_modulename fieldname, typexpr) )
                          fields
                      in
                      List.iter
                        (fun (fieldname, _) ->
                          Hashtbl.add toplevel.records fieldname typename )
                        fields ;
                      Hashtbl.add toplevel.records_fields typename
                      @@ List.map (fun (fieldname, _) -> fieldname) fields ;
                      P.DefRecord (typename, fields))
                entries ;
        P.Nope
    | P.ExpDef (expname, components) ->
        let expname = with_modulename expname in
        Hashtbl.add toplevel.exps expname expname ;
        toplevel.exps_list <- expname :: toplevel.exps_list ;
        P.Nope
    | P.OpenModuleDef modname ->
        let _, modname =
          hashtbl_find_with_modulename toplevel.modules (modname ^ ".")
        in
        toplevel.opened_modulename
        <- with_modulename modname :: modname :: toplevel.opened_modulename ;
        P.Nope
    | P.AppCls ((P.CtorApp (None, ctorname, None) as ctor), args) -> (
      match aux env ctor with
      | P.CtorApp (typename, ctorname, None) when List.length args = 1 ->
          P.CtorApp (typename, ctorname, Some (aux env @@ List.hd args))
      | _ -> failwith "invalid P.CtorApp" )
    | P.AppCls ((P.Var funcname as var), args) -> (
      try
        match
          match find_symbol env funcname with
          (* the symbol is 'safe' when it's in the same env
           * or it can be called by its name *)
          | 0, sym | _, (P.FuncVar _ as sym) -> sym
          | _, (P.Var id as sym) ->
              env.freevars := (funcname, id) :: !(env.freevars) ;
              sym
          | _ ->
              failwith @@ sprintf "not found variable in analysis: %s" funcname
        with
        | P.FuncVar (gen_funcname, nargs) ->
            let args = List.map (fun x -> aux env x) args in
            if List.length args = nargs then P.AppDir (gen_funcname, args)
            else
              let rec split n lst =
                if n = 0 then ([], lst)
                else
                  match lst with
                  | x :: xs ->
                      let lhs, rhs = split (n - 1) xs in
                      (x :: lhs, rhs)
                  | [] ->
                      failwith
                      @@ sprintf
                           "arguments to %s are too little: maybe curring?"
                           gen_funcname
              in
              let head, tail = split nargs args in
              P.AppCls (P.AppDir (gen_funcname, head), tail)
        | P.Var varname ->
            P.AppCls (aux env var, List.map (fun x -> aux env x) args)
        | _ -> raise Not_found
      with Not_found ->
        failwith (sprintf "not found in analysis (P.AppCls): %s" funcname) )
    | P.AppCls (func, args) ->
        P.AppCls (aux env func, List.map (fun x -> aux env x) args)
    | P.ForLoop (dir, indexname, expr1, expr2, expr3) ->
        let gen_indexname = make_id indexname in
        let env' =
          { env with
            symbols= Hashmap.add indexname (P.Var gen_indexname) env.symbols }
        in
        let expr1 = aux env expr1 in
        let expr2 = aux env expr2 in
        let expr3 = aux env' expr3 in
        P.ForLoop (dir, gen_indexname, expr1, expr2, expr3)
    | P.LetAnd (recursive, lhs_of_in, rhs_of_in) ->
        (* Split rhs_of_eq into P.LetVar and P.LetFunc. At the same time,
         * make a conversion table for function names *)
        let rec bind_with_modulename = function
          | ( P.IntValue _ | P.CharValue _ | P.UnitValue | P.EmptyList
            | P.PtnRange _ | P.StringValue _ ) as ptn ->
              ptn
          | P.TupleValue values ->
              P.TupleValue (List.map (fun x -> bind_with_modulename x) values)
          | P.Cons (car, cdr) ->
              P.Cons (bind_with_modulename car, bind_with_modulename cdr)
          | P.PtnAlias (ptn, (P.Var _ as var)) ->
              P.PtnAlias (bind_with_modulename ptn, bind_with_modulename var)
          | P.PtnOr (lhs, rhs) ->
              P.PtnOr (bind_with_modulename lhs, bind_with_modulename rhs)
          | P.CtorApp (None, ctorname, arg) ->
              let arg =
                match arg with
                | Some arg -> Some (bind_with_modulename arg)
                | _ -> None
              in
              P.CtorApp (None, ctorname, arg)
          | P.Var name ->
              (* This process is the key. In this function,
               * we put the current module name to the defined variables *)
              P.Var (with_modulename name)
          | _ -> failwith "unexpected pattern"
        in
        let funcnames2gen = Hashtbl.create 2 in
        let src =
          List.map
            (function
              | [P.Var funcname], rhs_of_eq when recursive ->
                  (* When recursive, P.LetVar should be P.LetFunc with no arguments. *)
                  (* TODO:
                    If the lhs doesn't have any freevars, then there is no need to convert it.
                    Also, we should check whether the lhs uses itself in a correct way e.g.
                        let rec length = function x :: xs -> 1 + length xs | [] -> 0;;
                    is okay, but
                        let rec id x = id;;
                    is ng. For now, we assume that 'let rec ...' expression is written properly.
                  *)
                  let funcname =
                    match rhs_of_in with
                    | Some _ -> funcname
                    | None -> with_modulename funcname
                  in
                  Hashtbl.add funcnames2gen funcname (make_id funcname) ;
                  P.LetFunc (true, funcname, [], rhs_of_eq, [])
              | [bind], rhs_of_eq ->
                  let bind =
                    match rhs_of_in with
                    | None -> bind_with_modulename bind
                    | Some _ -> bind
                  in
                  P.LetVar (recursive, bind, rhs_of_eq)
              | P.Var funcname :: args, rhs_of_eq ->
                  let funcname =
                    match rhs_of_in with
                    | Some _ -> funcname
                    | None -> with_modulename funcname
                  in
                  Hashtbl.add funcnames2gen funcname (make_id funcname) ;
                  P.LetFunc (recursive, funcname, args, rhs_of_eq, [])
              | _ -> failwith "unexpected ast")
            lhs_of_in
        in
        (* Now, analyze all P.LetVar/P.LetFunc.
         * When we analyze *recursive* P.LetFunc, we must decide whether
         * we should call this function by name or as closure in itself.
         * Therefore, first, we assume that we can call them by name i.e. we use P.FuncVar.
         * Next, if we find we can't do so (i.e. there are any freevars), we decide to call them as closure,
         * that is, use P.Var, and analyze it again.
         * I (ushitora-anqou) 'pakutta' or borrowed this idea from MinCaml.
         * TODO: is there better way?*)
        let let_closures_freevars = ref [] in
        let should_be_closure = ref false in
        let rec analyze_lets first =
          let toplevel_letfuncs_backup = toplevel.letfuncs in
          let toplevel_strings_backup = toplevel.strings in
          let funcvars =
            hashmap_of_list
            @@ filter_after_map
                 (function
                   | P.LetFunc (_, funcname, args, _, _) ->
                       let gen_funcname =
                         Hashtbl.find funcnames2gen funcname
                       in
                       Some
                         ( if first then
                           ( funcname
                           , P.FuncVar (gen_funcname, List.length args) )
                         else (funcname, P.Var gen_funcname) )
                   | _ -> None)
                 src
          in
          let rec aux' env' = function
            | P.LetVar (false, bind, lhs) ->
                let env' =
                  {env' with symbols= add_symbols_in_pattern env'.symbols bind}
                in
                (env', P.LetVar (false, aux_ptn env' bind, aux env lhs))
            | P.LetFunc (recursive, funcname, args, func, _) ->
                let gen_funcname = Hashtbl.find funcnames2gen funcname in
                let env_in =
                  { symbols= add_symbols_in_patterns Hashmap.empty args
                  ; parent= Some env
                  ; freevars= ref [] }
                in
                (* if recursive then funcname(s) should be in env *)
                let env_in =
                  if not recursive then env_in
                  else {env_in with symbols= integrate env_in.symbols funcvars}
                in
                let func = aux env_in func in
                (* Delete duplicate freevars *)
                env_in.freevars := list_unique !(env_in.freevars) ;
                let freevars =
                  ref (List.map (fun (_, a) -> a) !(env_in.freevars))
                in
                if first then (
                  (* Save data for the possible second loop *)
                  let_closures_freevars := !freevars @ !let_closures_freevars ;
                  (* If the function is recursive and should call itself as a closure,
                   * then P.Var should be used rather than P.FuncVar *)
                  if recursive && List.length !freevars <> 0 then
                    should_be_closure := true ;
                  if !should_be_closure then raise Should_be_closure ) ;
                let func =
                  if first then func
                  else (
                    (* In the target function, all functions chained with keyword 'and' should be available.
                     * This means that they should be defined as closures at the head of the target function.
                     * Note that these closures should have *all* freevars in chained functions. *)
                    (* TODO: only functions appeared in freevars need to be available. *)
                    freevars := !let_closures_freevars ;
                    P.LetAndAnalyzed
                      ( filter_after_map
                          (function
                            | P.LetFunc (_, funcname, args, _, _) ->
                                let gen_funcname =
                                  Hashtbl.find funcnames2gen funcname
                                in
                                Some
                                  (P.LetVar
                                     ( false
                                     , P.Var gen_funcname
                                     , P.MakeCls
                                         ( gen_funcname
                                         , List.length args
                                         , !let_closures_freevars ) ))
                            | _ -> None)
                          src
                      , func ) )
                in
                (* freevars are passed to env if they are not defined in env *)
                List.iter
                  (fun ((name, _) as var) ->
                    let d, _ = find_symbol env name in
                    if d <> 0 then env.freevars := var :: !(env.freevars) )
                  !(env_in.freevars) ;
                if List.length !freevars = 0 then (
                  (* no freevars; no need for closure *)
                  let env_out =
                    { env' with
                      symbols=
                        Hashmap.add funcname
                          (P.FuncVar (gen_funcname, List.length args))
                          env'.symbols }
                  in
                  let ast =
                    P.LetFunc
                      ( recursive
                      , gen_funcname
                      , List.map (fun x -> aux_ptn env_in x) args
                      , func
                      , [] )
                  in
                  toplevel.letfuncs <- ast :: toplevel.letfuncs ;
                  (env_out, ast) )
                else
                  (* closure *)
                  let funcvar = P.Var gen_funcname in
                  let env_out =
                    { env' with
                      symbols= Hashmap.add funcname funcvar env'.symbols }
                  in
                  let ast =
                    P.LetFunc
                      ( recursive
                      , gen_funcname
                      , List.map (fun x -> aux_ptn env_in x) args
                      , func
                      , !freevars )
                  in
                  toplevel.letfuncs <- ast :: toplevel.letfuncs ;
                  ( env_out
                  , P.LetVar
                      ( false
                      , funcvar
                      , P.MakeCls (gen_funcname, List.length args, !freevars)
                      ) )
            | _ -> raise P.Unexpected_ast
          in
          let env', lets =
            List.fold_left
              (fun (env', lets) le ->
                try
                  match le with
                  | P.LetVar _ ->
                      let env', le_analyzed = aux' env' le in
                      (env', le_analyzed :: lets)
                  | P.LetFunc _ ->
                      let env', le_analyzed = aux' env' le in
                      (env', le_analyzed :: lets)
                  | _ -> failwith "unexpected ast"
                with Should_be_closure when first -> (env', lets) )
              (env, []) src
          in
          if first && !should_be_closure then (
            toplevel.letfuncs <- toplevel_letfuncs_backup ;
            toplevel.strings <- toplevel_strings_backup ;
            let_closures_freevars := list_unique !let_closures_freevars ;
            analyze_lets false )
          else
            match rhs_of_in with
            | None -> raise (LetDef (lets, env'))
            | Some rhs -> P.LetAndAnalyzed (lets, aux env' rhs)
        in
        analyze_lets true
    | _ -> raise P.Unexpected_ast
  and analyze_module env exprs =
    let toplevel_env = ref env in
    let rec aux' exprs = function
      | P.ModuleAlias (modname, src_modname) :: asts ->
          let _, src_modname =
            hashtbl_find_with_modulename toplevel.modules @@ src_modname ^ "."
          in
          Hashtbl.add toplevel.modules
            (get_modulename_prefix (modname :: toplevel.modulename))
            src_modname ;
          aux' exprs asts
      | P.ModuleDef (this_modulename, body) :: asts ->
          toplevel.modulename <- this_modulename :: toplevel.modulename ;
          (* TODO: is there any better way? *)
          aux' exprs @@ body @ (P.ModuleDefEnd :: asts)
      | P.ModuleDefEnd :: asts ->
          let full_modname = get_modulename_prefix toplevel.modulename in
          Hashtbl.add toplevel.modules full_modname full_modname ;
          toplevel.modulename <- List.tl toplevel.modulename ;
          aux' exprs asts
      | P.ExternalDecl (id, typexpr, decl) :: asts ->
          let id = with_modulename id in
          let nargs =
            let rec aux cnt = function
              | Type.Func (lhs, rhs) -> aux (cnt + 1) rhs
              | _ -> cnt
            in
            aux 0 typexpr
          in
          toplevel_env :=
            { !toplevel_env with
              symbols=
                Hashmap.add id (P.FuncVar (decl, nargs)) !toplevel_env.symbols
            } ;
          aux' exprs asts
      | ast :: asts -> (
        try aux' (aux !toplevel_env ast :: exprs) asts
        with LetDef (lets, env) ->
          toplevel_env := env ;
          exprs2expr @@ List.rev
          @@ (P.LetAndAnalyzed (lets, aux' [] asts) :: exprs) )
      | [] -> exprs2expr @@ List.rev exprs
    in
    let ast = aux' [] exprs in
    (!toplevel_env, ast)
  in
  let env = {symbols= Hashmap.empty; parent= None; freevars= ref []} in
  let _, ast = analyze_module env asts in
  let ast = P.LetFunc (false, "aqaml_main", [P.UnitValue], ast, []) in
  toplevel.letfuncs <- ast :: toplevel.letfuncs ;
  (toplevel.letfuncs, toplevel.strings, toplevel.typedefs, toplevel.exps_list)
