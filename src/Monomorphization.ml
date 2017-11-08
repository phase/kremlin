(* Monomorphization of functions and data types. *)

open Ast
open PrintAst.Ops
open Helpers

module K = Constant

(* Monomorphization of data type definitions **********************************)

(* A whole-program map from type lids to their definitions. *)
let build_def_map files =
  build_map files (fun map -> function
    | DType (lid, flags, _, def) ->
        Hashtbl.add map lid (flags, def)
    | _ ->
        ()
  )

(* We visit type declarations in order to monomorphize parameterized type
 * declarations and insert forward declarations as needed. Consider, for
 * instance:
 *
 *   type linked_list = Nil | Cons of int * buffer linked_list
 *
 * We see this phase as a classic graph traversal where the nodes are pairs of
 * types and effective type arguments, and the edges are uses. The example above
 * is visited, then a forward declaration is inserted to break the cycle from
 * the node (linked_list, []) to itself. This gives:
 *
 *   type linked_list // a forward declaration
 *   type linked_list = Nil | Cons of int * buffer linked_list
 *
 * This will be turned into the following C code:
 *
 *   struct s;
 *   typedef struct s t;
 *   typedef struct s {
 *     int x;
 *     t *next;
 *   } t;
 *
 * We visit non-parameterized type declarations at declaration site.
 * However, parameterized declarations, such as the following, are visited at
 * use-site:
 *
 *   type linked_list a = | Nil | Cons: x:int -> buffer (linked_list a)
 *
 * This gives:
 *
 *   type linked_list_int;
 *   type linked_list_int = Nil | Cons of int * buffer linked_list_int
 *)
type node = lident * typ list
type color = Gray | Black
let monomorphize_data_types map = object(self)

  inherit [unit] map as super

  (* Assigning a color to each node. *)
  val state = Hashtbl.create 41
  (* We view tuples as the application of a special lid to its arguments. *)
  val tuple_lid = [ "K" ], ""
  (* We record pending declarations as we visit top-level declarations. *)
  val mutable pending = []

  (* Record a new declaration. *)
  method private record (d: decl) =
    pending <- d :: pending

  (* Clear all the pending declarations. *)
  method private clear () =
    let r = List.rev pending in
    pending <- [];
    r

  (* Compute the name of a given node in the graph. *)
  method private lid_of (n: node) =
    let lid, args = n in
    if List.length args > 0 then
      let doc = PPrint.(separate_map underscore PrintAst.print_typ args) in
      fst lid, KPrint.bsprintf "%s__%a" (snd lid) PrintCommon.pdoc doc
    else
      lid

  (* Prettifying the field names for n-uples. *)
  method private field_at i =
    match i with
    | 0 -> "fst"
    | 1 -> "snd"
    | 2 -> "thd"
    | _ -> Printf.sprintf "f%d" i

  (* Visit a given node in the graph, modifying [pending] to append in reverse
   * order declarations as they are needed, including that of the node we are
   * visiting. *)
  method private visit_node (n: node) =
    let lid, args = n in
    (* White, gray or black? *)
    begin match Hashtbl.find state n with
    | exception Not_found ->
        (* Subtletly: we decline to insert type monomorphizations in dropped
         * files, on the basis that they might be needed later in an actual
         * file. *)
        if lid = tuple_lid then
          (* For tuples, we immediately know how to generate a definition. *)
          let fields = List.mapi (fun i arg -> Some (self#field_at i), (arg, false)) args in
          self#record (DType (self#lid_of n, [], 0, Flat fields));
          Hashtbl.add state n Black
        else begin
          (* This specific node has not been visited yet. *)
          Hashtbl.add state n Gray;
          let subst fields = List.map (fun (field, (t, m)) ->
            field, (DeBruijn.subst_tn args t, m)
          ) fields in
          begin match Hashtbl.find map lid with
          | exception Not_found ->
              ()
          | flags, Variant branches ->
              let branches = List.map (fun (cons, fields) -> cons, subst fields) branches in
              let branches = self#branches_t () branches in
              self#record (DType (self#lid_of n, flags, 0, Variant branches))
          | flags, Flat fields ->
              let fields = self#fields_t () (subst fields) in
              self#record (DType (self#lid_of n, flags, 0, Flat fields))
          | flags, Abbrev t ->
              let t = DeBruijn.subst_tn args t in
              let t = self#visit_t () t in
              self#record (DType (self#lid_of n, flags, 0, Abbrev t))
          | _ ->
              ()
          end;
          Hashtbl.replace state n Black
        end
    | Gray ->
        begin match Hashtbl.find map lid with
        | exception Not_found ->
            ()
        | flags, _ ->
            self#record (DType (self#lid_of n, flags, 0, Forward))
        end
    | Black ->
        ()
    end;
    self#lid_of n

  (* Top-level, non-parameterized declarations are root of our graph traversal.
   * This also visits, via occurrences in code, applications of parameterized
   * types. *)
  method! visit_file _ file =
    let name, decls = file in
    name, KList.map_flatten (fun d ->
      match d with
      | DType (_, _, _, (Flat _ | Variant _ | Abbrev _)) ->
          ignore (self#visit_d () d);
          self#clear ()

      | _ ->
          self#clear () @ [ self#visit_d () d ]
    ) decls

  method! dtype env name flags n d =
    if n > 0 then
      (* This drops polymorphic type definitions by making them a no-op that
       * registers nothing. *)
      DType (name, flags, n, d)
    else
      super#dtype env name flags n d

  method! etuple _ _ es =
    EFlat (List.mapi (fun i e -> Some (self#field_at i), self#visit () e) es)

  method! ptuple _ _ pats =
    PRecord (List.mapi (fun i p -> self#field_at i, self#visit_pattern () p) pats)

  method! ttuple _ ts =
    TQualified (self#visit_node (tuple_lid, List.map (self#visit_t ()) ts))

  method! tqualified _ lid =
    TQualified (self#visit_node (lid, []))

  method! tapp _ lid ts =
    TQualified (self#visit_node (lid, List.map (self#visit_t ()) ts))
end

let datatypes files =
  let map = build_def_map files in
  let files = visit_files () (monomorphize_data_types map) files in
  files


(* Type monomorphization of functions. ****************************************)

module Gen = struct
  let generated_lids = Hashtbl.create 41
  let pending_defs = ref []

  let gen_lid lid ts =
    let doc =
      let open PPrint in
      let open PrintAst in
      separate_map underscore print_typ ts
    in
    fst lid, snd lid ^ KPrint.bsprintf "__%a" PrintCommon.pdoc doc

  let register_def original_lid ts lid def =
    Hashtbl.add generated_lids (original_lid, ts) lid;
    pending_defs := def () :: !pending_defs;
    lid

  let clear () =
    let r = List.rev !pending_defs in
    pending_defs := [];
    r
end


(* This follows the same structure as for data types, with a whole-program from
 * function & global lids to their respective definitions. Every type
 * application (caugh via the visitor) generates an instance. *)
let functions files =
  let map = Helpers.build_map files (fun map -> function
    | DFunction (cc, flags, n, t, name, b, body) ->
        if n > 0 then
          Hashtbl.add map name (`Function (cc, flags, n, t, name, b, body))
    | DGlobal (flags, name, n, t, body) ->
        if n > 0 then
          Hashtbl.add map name (`Global (flags, name, n, t, body))
    | _ ->
        ()
  ) in

  let monomorphize = object(self)

    inherit [unit] map

    method! visit_file _ file =
      let file_name, decls = file in
      file_name, KList.map_flatten (function
        | DFunction (cc, flags, n, ret, name, binders, body) ->
            if Hashtbl.mem map name then
              []
            else
              let d = DFunction (cc, flags, n, ret, name, binders, self#visit () body) in
              assert (n = 0);
              Gen.clear () @ [ d ]
        | DGlobal (flags, name, n, t, body) ->
            if Hashtbl.mem map name then
              []
            else
              let d = DGlobal (flags, name, n, t, self#visit () body) in
              assert (n = 0);
              Gen.clear () @ [ d ]
        | d ->
            [ d ]
      ) decls

    method etapp env _ e ts =
      match e.node with
      | EQualified lid ->
          begin try
            (* Already monomorphized? *)
            EQualified (Hashtbl.find Gen.generated_lids (lid, ts))
          with Not_found ->
            match Hashtbl.find map lid with
            | exception Not_found ->
                (* External function. Bail. *)
                (self#visit env e).node
            | `Function (cc, flags, n, ret, name, binders, body) ->
                (* Need to generate a new instance. *)
                if n <> List.length ts then begin
                  KPrint.bprintf "%a is not fully type-applied!\n" plid lid;
                  (self#visit env e).node
                end else
                  (* The thunk allows registering the name before visiting the
                   * body, for polymorphic recursive functions. *)
                  let name = Gen.gen_lid name ts in
                  let def () =
                    let ret = DeBruijn.subst_tn ts ret in
                    let binders = List.map (fun { node; typ } ->
                      { node; typ = DeBruijn.subst_tn ts typ }
                    ) binders in
                    let body = DeBruijn.subst_ten ts body in
                    let body = self#visit env body in
                    DFunction (cc, flags, 0, ret, name, binders, body)
                  in
                  EQualified (Gen.register_def lid ts name def)

            | `Global (flags, name, n, t, body) ->
                if n <> List.length ts then begin
                  KPrint.bprintf "%a is not fully type-applied!\n" plid lid;
                  (self#visit env e).node
                end else
                  let name = Gen.gen_lid name ts in
                  let def () =
                    let t = DeBruijn.subst_tn ts t in
                    let body = DeBruijn.subst_ten ts body in
                    let body = self#visit env body in
                    DGlobal (flags, name, 0, t, body)
                  in
                  EQualified (Gen.register_def lid ts name def)

          end
      | EOp (_, _) ->
         (self#visit env e).node
      | _ ->
          KPrint.bprintf "%a is not an lid in the type application\n" pexpr e;
          (self#visit env e).node

  end in

  Helpers.visit_files () monomorphize files
