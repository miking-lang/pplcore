-- Temporary implementation of CRBD example model, directly creating the AST.
-- TODO(dlunde,2020-10-19) Parse this as a regular program when support is
-- added for this in Miking.

include "math.mc"

-- TODO(dlunde,2020-10-19) I very much dislike using ".." in includes. I guess
-- we can fix this (by, e.g., adding the root of the repo to the path) when the
-- build procedure gets more mature.
include "../coreppl/ast.mc"
include "../coreppl/ast-builder.mc"

let crbd = use CorePPL in

  let leaf_ = lam age.
    conapp_ "Leaf" (record_ [("age", float_ age)])
  in

  let node_ = lam age. lam left. lam right.
    conapp_ "Node" (record_ [("age", float_ age),
                             ("l", left),
                             ("r", right)])
  in


  let tree =
    node_ 1.0 (leaf_ 0.0) (leaf_ 0.0)
  in

  let crbdGoesUndetected =
    ulams_ ["startTime", "lambda", "mu"]
      (bindall_ [
        let_ "t" (sampleExp_ (addi_ (var_ "lambda") (var_ "mu"))),
        let_ "currentTime" (subf_ (var_ "startTime") (var_ "t")),
        if_ (ltf_ (var_ "currentTime") (float_ 0.0))
          false_
          (bindall_ [
            let_ "speciation"
              (sampleBern_
                (divf_ (var_ "lambda") (addf_ (var_ "lambda") (var_ "mu")))),
            if_ (not_ (var_ "speciation"))
              true_
              (and_
                 (appf3_ (var_ "crbdGoesUndetected")
                    (var_ "currentTime") (var_ "lambda") (var_ "mu"))
                 (appf3_ (var_ "crbdGoesUndetected")
                    (var_ "currentTime") (var_ "lambda") (var_ "mu"))
              )
          ])
      ])
  in

  let simBranch =
    ulams_ ["startTime", "stopTime", "lambda", "mu"]
     (bindall_ [
       let_ "t" (sampleExp_ (var_ "lambda")),
       let_ "currentTime" (subf_ (var_ "startTime") (var_ "t")),
       if_ (ltf_ (var_ "currentTime") (float_ 0.0))
         unit_
         (bind_
           (let_ "_" (weight_ (app_ (var_ "log") (float_ 2.0))))
           (if_ (not_ (appf3_ (var_ "crbdGoesUndetected") (var_ "currentTime")
                         (var_ "lambda") (var_ "mu")))
             (weight_ (app_ (var_ "log") (float_ 0.0)))
             (appf4_ (var_ "simBranch")
                (var_ "currentTime") (var_ "stopTime")
                (var_ "lambda") (var_ "mu"))))
     ])
  in

  let simTree =
    let getAge = lam tree.
      match_ tree (pcon_ "Leaf" (prec_ [("age",(pvar_ "age"))]))
        (var_ "age")
        (match_ tree (pcon_ "Node" (prec_ [("age",(pvar_ "age"))]))
           (var_ "age") never_)
    in
    ulams_ ["tree", "parent", "lambda", "mu"]
      (bindall_ [
         let_ "pAge" (getAge (var_ "parent")),
         let_ "tAge" (getAge (var_ "tree")),
         let_ "_"
           (weight_
             (mulf_ (negf_ (var_ "mu"))
                (subf_ (var_ "pAge") (var_ "tAge")))),
         let_ "_" (resample_),
         let_ "_"
           (appf4_ (var_ "simBranch")
                 (var_ "pAge") (var_ "tAge")
                 (var_ "lambda") (var_ "mu")),
         match_ (var_ "tree")
           (pcon_ "Node" (prec_ [("l",(pvar_ "left")),("r",(pvar_ "right"))]))
           (bindall_ [
             let_ "_" (weight_ (app_ (var_ "log") (var_ "lambda"))),
             let_ "_" (resample_),
             let_ "_"
               (appf4_ (var_ "simTree") (var_ "left")
                  (var_ "tree") (var_ "lambda") (var_ "mu")),
             (appf4_ (var_ "simTree") (var_ "right")
                (var_ "tree") (var_ "lambda") (var_ "mu"))
           ])
           unit_
       ])
  in

  bindall_ [
    let_ "log" unit_, -- TODO Need log implementation?

    ucondef_ "Leaf",
    ucondef_ "Node",

    let_ "tree" tree,

    reclet_ "crbdGoesUndetected" crbdGoesUndetected,

    reclet_ "simBranch" simBranch,
    reclet_ "simTree" simTree,

    let_ "lambda" (float_ 0.2),
    let_ "mu" (float_ 0.1),

    let_ "_" (weight_ (app_ (var_ "log") (float_ 2.0))),

    match_ (var_ "tree")
      (pcon_ "Node" (prec_ [("l",(pvar_ "left")),("r",(pvar_ "right"))]))
      (bindall_ [
         let_ "_" (appf4_ (var_ "simTree") (var_ "left")
                     (var_ "tree") (var_ "lambda") (var_ "mu")),
         let_ "_" (appf4_ (var_ "simTree") (var_ "right")
                     (var_ "tree") (var_ "lambda") (var_ "mu")),
         tuple_ [(var_ "lambda"), (var_ "mu")]
      ])
      never_
  ]
