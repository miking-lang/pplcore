(** Inference algorithms *)

open Ast
open Sprint
open Debug
open Utils
open Eval
open Printf

(** Mapping between predefined variable names and builtin constants *)
let builtin = [

  "not",          VNot{at=va};
  "and",          VAnd{at=va;b1=None};
  "or",           VOr{at=va;b1=None};

  "mod",          VMod{at=va;i1=None};
  "sll",          VSll{at=va;i1=None};
  "srl",          VSrl{at=va;i1=None};
  "sra",          VSra{at=va;i1=None};

  "inf",          VFloat{at=va;f=infinity};
  "log",          VLog{at=va};

  "add",          VAdd{at=va;v1=None};
  "sub",          VSub{at=va;v1=None};
  "mul",          VMul{at=va;v1=None};
  "div",          VDiv{at=va;v1=None};
  "neg",          VNeg{at=va};
  "lt",           VLt{at=va;v1=None};
  "leq",          VLeq{at=va;v1=None};
  "gt",           VGt{at=va;v1=None};
  "geq",          VGeq{at=va;v1=None};

  "eq",           VEq{at=va;v1=None};
  "neq",          VNeq{at=va;v1=None};

  "normal",       VNormal{at=va;mu=None;sigma=None};
  "uniform",      VUniform{at=va;a=None;b=None};
  "gamma",        VGamma{at=va;a=None;b=None};
  "exponential",  VExp{at=va;lam=None};
  "bernoulli",    VBern{at=va;p=None};

  "logpdf",       VLogPdf{at=va;v1=None};
  "sample",       VSample{at=va};
  "resample",     VResamp{at=va;dyn=false;cont=None};

  "fix",          VFix{at=va};

] |> List.map (fun (x, y) -> x, tm_of_val y)

(** Create a string representation of builtins *)
let string_of_builtin ?(labels = false) builtin =
  String.concat "\n"
    (List.map (fun (x, y) -> sprintf "%s = %s" x
                  (string_of_tm ~labels:labels ~pretty:false y)) builtin)

(** Inference types *)
type inference =
  | Eval
  | Importance
  | SMCDirect
  | SMCManual
  | SMCDynamic
  | SMCStatic

(** Default inference is simply weighted evaluation *)
let inference = ref Eval

(** Number of samples for inference algorithms *)
let samples = ref 10

(** Compute the logarithm of the average of a list of n weights using
    logsumexp-trick *)
let logavg n weights =
  let max = List.fold_left max (-. infinity) weights in
  log (List.fold_left (fun s w -> s +. exp (w -. max)) 0.0 weights)
  +. max -. log (float n)

(* Function for producing a nicely formatted string representation of the
   empirical distributions returned by infer below. Aggregates samples with the
   same value to produce a more compact output.
   TODO The sorting function fails with stack overflow for large number of
   samples. *)
let string_of_empirical
    ?(aggregate = true)
    ?(normalize = true)
    ?(log_weights = false) ls =

  (* Normalize if arg is given *)
  let res = if normalize then
      (* Compute the logarithm of the average of the weights *)
      let logavg = logavg !samples (List.map fst ls) in

      (* Compute normalized weights *)
      Utils.map (fun (w,t) -> w-.logavg-.(log (float_of_int !samples)),t) ls
    else
      ls
  in

  (* Convert from log weights to ordinary weights, depending on arg *)
  let res = if log_weights then
      res
    else
      Utils.map (fun (w,t) -> exp w,t) res
  in

  (* Aggregate equal samples depending on argument (only available if using
     ordinary weights) *)
  let res =
    if aggregate && not log_weights then
      let res =
        List.sort (fun (_,v1) (_,v2) -> Compare.compare v1 v2) res in
      let rec aggregate acc ls = match acc,ls with
        | (w1,v1,n)::acc,(w2,v2)::ls when v1 = v2 ->
          aggregate ((w1+.w2,v1,n+1)::acc) ls
        | acc, (w,v)::ls ->
          aggregate ((w,v,1)::acc) ls
        | acc, [] -> acc
      in aggregate [] res
    else
      Utils.map (fun (w,v) -> (w,v,1)) res
  in

  (* Sort based on weight to show the sample with highest weight at the top *)
  let res = List.sort
      (fun (w1,_,_) (w2,_,_) -> - Pervasives.compare w1 w2) res in

  (* Convert values to strings *)
  let res = List.map
      (fun (w,v,n) -> w,string_of_val ~max_boxes:5 ~margin:max_int v,n) res in

  (* Check if the #SAMPLES column should be printed *)
  let is_aggr = List.exists (fun (_,_,n) -> n > 1) res in

  (* Column width for printout *)
  let cw = 15 in

  (* Function for printing one sample *)
  let line (w,v,n) = if is_aggr then
      sprintf "  %-*f%-*d%s" cw w cw n v
    else
      sprintf "  %-*f%s" cw w v
  in

  (* The weight header changes depending on if the weights are logarithmic or
     not. *)
  let weight_header = if log_weights then "LOG WEIGHT" else "WEIGHT" in

  (* Header *)
  let header = if is_aggr then
      sprintf "%-*s%-*s%s\n" cw weight_header cw "#SAMPLES" "SAMPLE"
    else
      sprintf "%-*s%s\n" cw weight_header "SAMPLE"
  in

  (* Print headers and all samples *)
  header ^ (String.concat "\n" (Utils.map line res))


(** Importance sampling
    (or more specifically, likelihood weighting) inference *)
let infer_is env program =

  (* Replicate program for #samples times *)
  let s = replicate !samples program in

  (* Evaluate everything to the end, producing a set of weighted samples *)
  let res = Utils.map (eval false env 0.0) s in

  (* Calculate normalizing constant and return *)
  logavg !samples (Utils.map fst res),res


(* Systematic resampling of n samples *)
let resample s =

  (* Compute part of the normalizing constant *)
  let logavg = logavg !samples (List.map fst s) in

  (* Compute normalized weights from log-weights *)
  let snorm = List.map (fun (w,t) -> exp (w -. logavg),t) s in

  (* Draw offset for resampling *)
  let offset = Random.float 1.0 in

  (* Perform resampling *)
  let rec rec1 curr next snorm acc = match snorm with
    | (w,_)::_ -> let curr = curr +. w in rec2 curr next snorm acc
    | [] -> acc
  and rec2 curr next snorm acc = match snorm with
    | (_,t)::tail ->
      if curr > next then rec2 curr (next +. 1.0) snorm ((0.0,t)::acc)
      else rec1 curr next tail acc
    | [] -> failwith "Error in resampling" in

  (* Also return the log average for computing the normalization constant *)
  logavg, rec1 0.0 offset snorm []

(** SMC inference *)
let infer_smc env program =

  (* Replicate program for #samples times. *)
  let s = replicate !samples program in

  (* Function for wrapping a continuation for further evaluation. Set the
     attribute of the unit argument to at. *)
  let app_cont cont at =
    (TApp{at=ta; t1=tm_of_val cont; t2=TVal{at=ta;v=VUnit{at=at}}}) in

  (* Run a particle until the next resampling point *)
  let rec eval stoch_ctrl env w t = match Eval.eval stoch_ctrl env w t with

    (* If the resample is dynamic and control is stochastic, just continue
       evaluation. *)
    | w,VResamp{at;dyn=true;
                cont=Some(VClos{cont=true;stoch_ctrl;_} as cont);_} as res ->
      if stoch_ctrl then begin
        debug debug_smc_dyn "Skipping resampling"
          (fun () -> sprintf "Weight %f" w);
        eval stoch_ctrl [] w (app_cont cont at)
      end else res

    (* Static resample. Always perform resampling *)
    | _,VResamp{dyn=false; cont=Some(VClos{cont=true;_});_} as res -> res

    (* Incorrect resample *)
    | _,VResamp _ -> failwith "Erroneous VResamp in infer_smc"

    (* Result value and weight *)
    | w,v -> w,v

  in

  (* Run until first resample, attaching the initial environment *)
  let s = Utils.map (eval false env 0.0) s in

  (* Run SMC *)
  let rec recurse s normconst =

    (* Check if we need to resample *)
    if List.exists
        (fun (_,v) -> match v with VResamp _ -> true | _ -> false) s
    then begin
      debug debug_smc "Resample"
        (fun () -> string_of_empirical
            ~log_weights:true ~normalize:false s);

      (* Do the resampling and accumulate normalization constant *)
      let logavg, s = resample s in
      let normconst = normconst +. logavg in

      (* Run particles until next resampling point *)
      let continue v = match v with
        | VResamp{at;cont=Some(VClos{stoch_ctrl;_} as cont);_} ->
          eval stoch_ctrl [] 0.0 (app_cont cont at)
        | _ -> 0.0,v in
      let s = Utils.map (fun (_,v) -> continue v) s in

      recurse s normconst
    end else
      normconst,s

  in recurse s 0.0

(** Convert all weightings in the program to
    weightings followed by calls to resample *)
let add_resample ~dyn builtin t =
  let rec recurse t = match t with
    | TVar _ -> t
    | TApp{at;t1;t2} -> TApp{at;t1=recurse t1;t2=recurse t2}
    | TLam({t1;_} as t) -> TLam{t with t1=recurse t1}
    | TIf{at;t1;t2} -> TIf{at;t1=recurse t1;t2=recurse t2}
    | TMatch{at;cls} -> TMatch{at;cls=List.map (fun (p,t) -> p,recurse t) cls}
    | TVal{at;v=VWeight _} ->
      let var, var'  = makevar "w" noidx in
      let weight_app = TApp{at=ta;t1=t;t2=var'} in
      let resamp     = TApp{at=ta;
                            t1=TVal{at=ta;v=VResamp{at=va;dyn=dyn;cont=None}};
                            t2=nop} in
      TLam{at=at;vat=xa;cont=false;x=var;t1=seq weight_app resamp}
    | TVal _ -> t
  in recurse t, List.map (fun (x,t) -> x,recurse t) builtin

(** Transform term and builtins to CPS *)
let cps tm builtin =
  (* Transform builtins to CPS. Required since we need to wrap constant
     functions in CPS forms *)
  let builtin = List.map (fun (x, y) -> (x, (Cps.cps_atomic y))) builtin in

  debug debug_cps "Post CPS builtin"
    (fun () -> string_of_builtin builtin);


  (* Perform CPS transformation of main program *)
  let tm = Cps.cps tm in

  debug debug_cps "Post CPS"
    (fun () -> string_of_tm ~pretty:false tm);

  tm,builtin

(** Preprocess a program in preparation for running inference. *)
let preprocess tm builtin =
  match !inference with

  (* No preprocessing required if not running SMC *)
  | Eval | Importance -> tm,builtin

  (* For direct SMC, add resamples after each weight and then do the CPS
     transformation *)
  | SMCDirect ->
    let tm,builtin = add_resample ~dyn:false builtin tm in

    debug debug_resample_transform "After attaching resamples"
      (fun () -> string_of_tm tm);

    cps tm builtin

  (* For manual SMC, just do the CPS transformation. It is the users
     responsibility to add resample points in the program *)
  | SMCManual -> cps tm builtin

  (* For dynamic SMC, add dynamic resamples after each weight and then do the
     CPS transformation *)
  | SMCDynamic ->
    let tm,builtin = add_resample ~dyn:true builtin tm in

    debug debug_resample_transform "After attaching dynamic resamples"
      (fun () -> string_of_tm tm);

    cps tm builtin

  (* TODO *)
  | SMCStatic -> failwith "Static SMC not yet implemented"

(** Preprocess term and redirect to inference algorithm provided on command
    line. *)
let infer tm =

  (* Perform inference-specific preprocessing *)
  let tm,builtin = preprocess tm builtin in

  (* Calculate debruijn indices *)
  let tm = debruijn (builtin |> List.split |> fst) tm in
  let builtin = List.map (fun (x, y) -> (x, debruijn [] y)) builtin in

  (* Variable names no longer required due to debruijn indices *)
  let env = (builtin |> List.split |> snd) in

  match !inference with
  | Eval       -> let logavg,v = eval false env 0.0 tm in logavg,[logavg,v]
  | Importance -> infer_is env tm
  | SMCDirect  | SMCManual
  | SMCDynamic | SMCStatic -> infer_smc env tm
