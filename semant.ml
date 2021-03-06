(* Semantic checking for the MicroC compiler *)

open Ast
open Sast

module StringMap = Map.Make(String)

(* Semantic checking of the AST. Returns an SAST if successful,
   throws an exception if something is wrong.

   Check each global variable, then check each function *)


let check (globals, functions) =

  let sndt x = match x with 
                |VarDecl (_, b, _) -> b 
  in

  (**** Checking Functions ****)

  (* Collect function declarations for built-in functions: no bodies *)
  let built_in_decls = 
    let add_bind map (name, tylist, rtyp) = StringMap.add name {
      ftyp = rtyp; fname = name; 
      formals = List.map (fun t -> (VarDecl(t,"x",Noexpr))) tylist;
      locals = []; body = [] } map
    in List.fold_left add_bind StringMap.empty [ 
                                     ("openfile", [String; Int], String);
                                     ("writefile", [String; String; Int], String);
                                     ("print", [Int], Void);
                                     ("prints", [String], Void);
			                         ("printb", [Bool], Void);
			                         ("printf", [Float], Void);
			                         ("printbig", [Int], Void) ]
  in

  (* Add function name to symbol table *)
  let add_func map fd = 
    let built_in_err = "function " ^ fd.fname ^ " is a built-in function and may not be redefined"
    and dup_err = "duplicate function " ^ fd.fname
    and make_err er = raise (Failure er)
    and n = fd.fname (* Name of the function *)
    in match fd with (* No duplicate functions or redefinitions of built-ins *)
         _ when StringMap.mem n built_in_decls -> make_err built_in_err
       | _ when StringMap.mem n map -> make_err dup_err  
       | _ ->  StringMap.add n fd map 
  in

  (* Collect all other function names into one symbol table *)
  let function_decls = List.fold_left add_func built_in_decls functions
  in
  
  (* Return a function from our symbol table *)
  let find_func s = 
    try StringMap.find s function_decls
    with Not_found -> raise (Failure ("unrecognized function " ^ s))
  in

  let _ = find_func "main" in (* Ensure "main" is defined *)



  let rec var_decl_typ_checking e =
      match e with 
        Literal  l -> Int
      | Fliteral l -> Float
      | BoolLit l  -> Bool
      | Sliteral s -> String
      | Noexpr     -> Void
      | Array_Lit l -> array_lit_check(l)
      | _ -> raise (Failure "Variable declaration only supports primitive type initialization")

      and

      array_lit_check l = match l with
      |[]-> raise (Failure "Empty array literals")
      |[a] -> let a_ty = var_decl_typ_checking a in
              if a_ty == Void then raise(Failure "Only primitive types are supported in arrays")
              else Arr(a_ty, 1)
      |a::b -> let a_ty = var_decl_typ_checking a in
               let Arr(b_ty, size) = array_lit_check b in
               if not (a_ty = b_ty) then raise (Failure "Array literals are not in uniformed types")
               else Arr(a_ty, size+1)
    in

      (* Check if a certain kind of binding has void type or is a duplicate
     of another, previously checked binding *)
  let check_var_decl (kind : string) (var_list : var_decl list) map= 
    let check_it (checked,m) var_decl= 
      let void_err = "illegal void " ^ kind ^ " " ^ sndt var_decl
      and dup_err = "duplicate " ^ kind ^ " " ^ sndt var_decl
      in match var_decl with
        (* No void bindings *)
        VarDecl (Void, _, _) -> raise (Failure void_err)
(*        | VarDecl (_, n1, _) -> *) 
       | VarDecl (ty1, n1, e) -> 
          let m2 = StringMap.add n1 ty1 m in
          let ty2 = var_decl_typ_checking e in
            match ty1 with 
            |Arr (a_ty, size) -> (match ty2 with
                                  |Arr(b_ty, size2) -> if not (a_ty = b_ty) then raise (Failure "Array literal types not matching array declaration type") else if size != size2 then raise (Failure "Array literal size not matching array declaration size") else
                                      (match checked with
                                      (* No duplicate variable_declarations *)
                                      (VarDecl (_, n2, _) :: _) when n1 = n2 -> raise (Failure dup_err)
                                      | _ -> var_decl :: checked), m2
                                  |_ -> raise (Failure "Array not initalized to the right array literals"))
            |_->
                let type_err =  "type " ^ string_of_typ ty1 ^ " does not match type " ^ string_of_typ ty2 ^" in the variable declaration " ^ string_of_vdecl var_decl in
                if ty1 != ty2 && ty2 != Void then raise (Failure type_err)
                else
                  match checked with
                (* No duplicate variable_declarations *)
                        (VarDecl (_, n2, _) :: _) when n1 = n2 -> raise (Failure dup_err)
                        | _ -> var_decl :: checked, m2
    in let _,m = List.fold_left check_it ([], map) (List.sort compare var_list) 
       in var_list, m
  in 


  (**** Checking Global Variables ****)

  let globals', gmap = check_var_decl "global" globals StringMap.empty in

    let check_function func =
    (* Make sure no formals or locals are void or duplicates *)
    let formals', fmap = check_var_decl "formal" func.formals gmap in
    let locals', lmap = check_var_decl "local" func.locals fmap in

    (* Raise an exception if the given rvalue type cannot be assigned to
       the given lvalue type *)
    let check_assign lvaluet rvaluet err =
       if lvaluet = rvaluet then lvaluet else raise (Failure err)
    in   

    
(* Build local symbol table of variables for this function *)
    let symbols = List.fold_left (fun m x -> match x with 
                                                  |VarDecl(ty, name, _) -> StringMap.add name ty m)
                  StringMap.empty (globals' @ formals' @ locals')
    in

    (* Return a variable from our local symbol table *)
    let type_of_identifier s =
      try StringMap.find s symbols
      with Not_found -> raise (Failure ("undeclared identifier " ^ s))
    in

let rec get_layer_and_name array_expr = 
  match array_expr with
  | Id s -> 1, s
  | Array_Index (arr, _) -> let layer, name = get_layer_and_name arr in layer+1, name
  | _ -> raise (Failure "illegal usage of get_layer_and_name function")
in

let rec get_actual_type ty layer = 
  match layer with
  | 0 -> ty
  | _ -> match ty with 
          |Arr(ty2, _) -> get_actual_type ty2 (layer - 1)
          |_ -> raise (Failure "illegal usage of get_actual_type function")

in
let get_array_index_type array_expr map = 
  let layer, name = get_layer_and_name(array_expr) in
  let ty = StringMap.find name map in
  get_actual_type ty layer 
in

(* 
let rec get_array_literal_type l = 
  match l with 
  |[] -> raise (Failure "array literals cannot be empty")
  |[a] -> let ty, _ = expr a in 
in *)

(* Return a semantically-checked expression, i.e., with a type *)
    let rec expr e = match e with
        Literal  l -> (Int, SLiteral l)
      | Fliteral l -> (Float, SFliteral l)
      | BoolLit l  -> (Bool, SBoolLit l)
      | Noexpr     -> (Void, SNoexpr)
      | Id s       -> (type_of_identifier s, SId s)
      | Sliteral s -> (String, SSliteral s)
      | Array_Index (arr(*expr*), ind) ->
      let ind' =
        match expr ind with
        | Int, ind' -> ind'
        | _ -> failwith ("expected integer index " ^ string_of_expr ind ^
                         " in " ^ string_of_expr e)
      in
      (get_array_index_type arr lmap), SArray_Index (arr, ind)
      | Array_Lit l -> raise (Failure "array literals cannot be reassigned and they can only be initialized or modified by individual element")
      (* Check array size and equality of element types *)
      (* TODO: in LRM say that implicit conversions do (* not apply to array literals *)
      (match l with
       | [] -> failwith ("illegal empty array " ^ string_of_expr e)
       | hd :: tl ->
         let (lt, hd') = expr hd in
         let tl' = List.map (fun l ->
             let t, e' = expr l in
             let _, e'' = check_assign_strict lt e' t
                 ("array literal " ^ string_of_expr e ^
                  " contains elements of unequal types "
                  ^ string_of_typ lt ^ " and " ^ string_of_typ t)
             in e'') tl
         in *)
(*          Arr (Int, 0), SArray_Lit([]) *)
      | Assign(var, e) as ex -> 
          let (lt, _) = expr var
          and (rt, e') = expr e in
          let err = "illegal assignment " (* ^ string_of_typ lt ^ " = " ^ 
            string_of_typ rt ^ " in " (* ^ string_of_expr ex *) *)
          in (check_assign lt rt err, SAssign(expr var, (rt, e')))
      | Unop(op, e) as ex -> 
          let (t, e') = expr e in
          let ty = match op with
            Neg when t = Int || t = Float -> t
          | Not when t = Bool -> Bool
          | _ -> raise (Failure ("illegal unary operator " ^ 
                                 string_of_uop op ^ string_of_typ t ^
                                 " in " ^ string_of_expr ex))
          in (ty, SUnop(op, (t, e')))
      | Binop(e1, op, e2) as e -> 
          let (t1, e1') = expr e1 
          and (t2, e2') = expr e2 in
          (* All binary operators require operands of the same type *)
          let same = t1 = t2 in
          (* Determine expression type based on operator and operand types *)
          let ty = match op with
            Add | Sub | Mult | Div when same && t1 = Int   -> Int
          | Add | Sub | Mult | Div when same && t1 = Float -> Float
          | Equal | Neq            when same               -> Bool
          | Less | Leq | Greater | Geq
                     when same && (t1 = Int || t1 = Float) -> Bool
          | And | Or when same && t1 = Bool -> Bool
          | _ -> raise (
        Failure ("illegal binary operator " ^
                       string_of_typ t1 ^ " " ^ string_of_op op ^ " " ^
                       string_of_typ t2 ^ " in " ^ string_of_expr e))
          in (ty, SBinop((t1, e1'), op, (t2, e2')))
      | Call(fname, args) as call -> 
          let fd = find_func fname in
          let param_length = List.length fd.formals in
          if List.length args != param_length then
            raise (Failure ("expecting " ^ string_of_int param_length ^ 
                            " arguments in " ^ string_of_expr call))
          else let check_call x e = match x with
          |VarDecl(ft, _, _) ->
            let (et, e') = expr e in 
            let err = "illegal argument found " ^ string_of_typ et ^
              " expected " ^ string_of_typ ft ^ " in " ^ string_of_expr e
            in (check_assign ft et err, e')
          in 
          let args' = List.map2 check_call fd.formals args
          in (fd.ftyp, SCall(fname, args'))
    in

    let check_bool_expr e = 
      let (t', e') = expr e
      and err = "expected Boolean expression in " ^ string_of_expr e
      in if t' != Bool then raise (Failure err) else (t', e') 
    in

    (* Return a semantically-checked statement i.e. containing sexprs *)
    let rec check_stmt = function
        Expr e -> SExpr (expr e)
      | If(p, b1, b2) -> SIf(check_bool_expr p, check_stmt b1, check_stmt b2)
      | For(e1, e2, e3, st) ->
	  SFor(expr e1, check_bool_expr e2, expr e3, check_stmt st)
      | While(p, s) -> SWhile(check_bool_expr p, check_stmt s)
      | Return e -> let (t, e') = expr e in
        if t = func.ftyp then SReturn (t, e') 
        else raise (
	  Failure ("return gives " ^ string_of_typ t ^ " expected " ^
		   string_of_typ func.ftyp ^ " in " ^ string_of_expr e))
	    
	    (* A block is correct if each statement is correct and nothing
	       follows any Return statement.  Nested blocks are flattened. *)
      | Block sl -> 
          let rec check_stmt_list = function
              [Return _ as s] -> [check_stmt s]
            | Return _ :: _   -> raise (Failure "nothing may follow a return")
            | Block sl :: ss  -> check_stmt_list (sl @ ss) (* Flatten blocks *)
            | s :: ss         -> check_stmt s :: check_stmt_list ss
            | []              -> []
          in SBlock(check_stmt_list sl)

    in (* body of check_function *)
    { sftyp = func.ftyp;
      sfname = func.fname;
      sformals = formals';
      slocals  = locals';
      sbody = match check_stmt (Block func.body) with
	SBlock(sl) -> sl
      | _ -> let err = "internal error: block didn't become a block?"
      in raise (Failure err)
    }
  in (globals', List.map check_function functions)
