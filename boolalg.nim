import sequtils
import streams
import strutils

type
  BVar = distinct string

  BExpKind = enum
    BEVar, BESum, BEProd, BETrue, BEFalse, BENot

  BExp* = ref object
    case kind*: BExpKind
    of BEVar:
      bvar*: BVar
    of BESum, BEProd:
      lhs*: BExp
      rhs*: BExp
    of BETrue, BEFalse: discard
    of BENot:
      exp*: BExp

  BExpSimplStep = tuple[res: BExp, comment: string, substep: BExpSimplifier]
  BExpSimplifier* = ref object
    history: seq[BExpSimplStep]
    current: BExp


let BFalse = BExp(kind: BEFalse)
let BTrue = BExp(kind: BETrue)


proc v*(s: string): BExp = BExp(kind: BEVar, bvar: BVar(s))

proc `*`*(lhs, rhs: BExp): BExp = BExp(kind: BEProd, lhs: lhs, rhs: rhs)
proc `+`*(lhs, rhs: BExp): BExp = BExp(kind: BESum, lhs: lhs, rhs: rhs)
proc `-`*(exp: BExp): BExp = BExp(kind: BENot, exp: exp)
proc `$`*(exp: BExp): string
proc `==`*(lhs, rhs: BExp): bool

proc addStep(simpl: BExpSimplifier, next: BExp, comment: string)
proc newBExpSimplifier(exp: BExp): BExpSimplifier =
  new result
  newSeq(result.history, 0)
  result.history.add( (exp, "Start", nil) )
  result.current = exp

proc addStep(simpl: BExpSimplifier, next: BExp, comment: string) =
  for index, historyItem in simpl.history:
    if not isNil(historyItem.res):
      if historyItem.res == next:
        return
  simpl.history.add( (next, comment, nil) )
  simpl.current = next

proc addSubstep(simpl: BExpSimplifier, subSimpl: BExpSimplifier, comment: string) =
  simpl.history.add( (nil, comment, subSimpl) )

proc addSubstep(simpl: BExpSimplifier, subStepStart: BExp, comment: string): BExpSimplifier =
  let subSimpl = newBExpSimplifier(subStepStart)
  simpl.addSubStep(subSimpl, comment)
  return subSimpl

proc pruneUselessSteps(simpl: BExpSimplifier) =
  # Go through and remove any substeps that start and end with the same thing
  var index = simpl.history.len
  while index > 0:
    dec index

    if not isNil(simpl.history[index].substep):
      let substep = simpl.history[index].substep
      substep.pruneUselessSteps()
      if substep.current == substep.history[0].res:
        simpl.history.delete(index)


proc write(s: Stream, simpl: BExpSimplifier, indent = 0) =
  for step in simpl.history:
    s.write(repeat(' ', indent))
    if step.substep.isNil:
      s.write($step.res)
      s.write(repeat(' ', 30 - ($step.res).len))
      s.write(step.comment)
    else:
      s.write(step.substep, indent + 1)
    s.write("\n")


proc containsAll[T](s1, s2: openArray[T]): bool =
  for el in s2:
    if el notin s1:
      return false

  return true

proc setEquals[T](s1, s2: openArray[T]): bool =
  s1.len == s2.len and s1.containsAll(s2)

proc setCompare[T](s1, s2: openArray[T], common, extra: var seq[T]) =

  for el in s1:
    if el notin s2:
      extra.add(el)
    else:
      common.add(el)

  for el in s2:
    if el notin s1:
      extra.add(el)

proc filterFalseTerms(terms: var seq[BExp]) =
  terms.keepItIf(it != BFalse)

proc filterTrueTerms(terms: var seq[BExp]) =
  terms.keepItIf(it != BTrue)

proc product*(terms: seq[BExp]): BExp =
  if terms.len == 0:
    BTrue
  else:
    foldl(terms, a * b)

proc sum*(terms: seq[BExp]): BExp =
  if terms.len == 0:
    BFalse
  else:
    foldl(terms, a + b)


proc collectSumTerms(exp: BExp): seq[BExp] =
  newSeq(result, 0)
  if exp.kind == BESum:
    result.add(collectSumTerms(exp.lhs))
    result.add(collectSumTerms(exp.rhs))
  else:
    result.add(exp)

proc collectProdTerms(exp: BExp): seq[BExp] =
  newSeq(result, 0)
  if exp.kind == BEProd:
    result.add(collectProdTerms(exp.lhs))
    result.add(collectProdTerms(exp.rhs))
  else:
    result.add(exp)

proc `==`*(lhs, rhs: BExp): bool =
  if lhs.kind != rhs.kind:
    return false

  case lhs.kind:
    of BETrue, BEFalse:
      return true
    of BEVar:
      return string(lhs.bvar) == string(rhs.bvar)
    of BENot:
      return lhs.exp == rhs.exp
    of BESum, BEProd:
      # collect all terms and compare the sets
      let collectProc = if lhs.kind == BESum: collectSumTerms else: collectProdTerms
      let lhsTerms = collectProc(lhs)
      let rhsTerms = collectProc(rhs)

      return lhsTerms.setEquals(rhsTerms)

proc parenthesize(exp: BExp, kinds: set[BExpKind]): string =
  if exp.kind in kinds:
    "(" & $exp & ")"
  else:
    $exp

proc `$`*(exp: BExp): string =
  case exp.kind:
    of BEVar:
      return string(exp.bvar)
    of BESum:
      return $exp.lhs & " + " & $exp.rhs
    of BEProd:
      var kinds = {BESum, BETrue, BEFalse}
      var lhsStr = parenthesize(exp.lhs, kinds)
      var rhsStr = parenthesize(exp.rhs, kinds)

      return lhsStr & rhsStr
    of BETrue:
      return "1"
    of BEFalse:
      return "0"
    of BENot:
      var str = parenthesize(exp.exp, {BESum, BEProd, BENot})
      return str & "'"

# converts POS to SOP
proc killPOS(simpl: BExpSimplifier) =
  let exp = simpl.current
  case exp.kind:
    of BEVar, BETrue, BEFalse:
      return
    of BENot:
      if exp.exp.kind in {BESum, BEProd}:
        # Apply DeMorgan's law: (a + b)' = a'b'
        let sublhs = simpl.addSubstep(exp.exp.lhs, "Simplify left hand side")
        let subrhs = simpl.addSubstep(exp.exp.rhs, "Simplify right hand side")
        sublhs.killPOS()
        subrhs.killPOS()
        if exp.exp.kind == BESum:
          simpl.addStep((-sublhs.current) * (-subrhs.current), "Apply DeMorgan's law: (a + b)' = a'b'")
        else:
          simpl.addStep((-sublhs.current) + (-subrhs.current), "Apply DeMorgan's law: (ab)' = a' + b'")
        simpl.killPOS()
      elif exp.exp.kind == BENot:
        simpl.addStep(exp.exp.exp, "Eliminate double negative")
        simpl.killPOS()
      else:
        let sub = simpl.addSubstep(exp.exp, "Simplify inside NOT")
        sub.killPOS()
        simpl.addStep(-sub.current, "Reapply NOT")
    of BESum:
      let sublhs = simpl.addSubstep(exp.lhs, "Simplify left hand side")
      let subrhs = simpl.addSubstep(exp.rhs, "Simplify right hand side")
      sublhs.killPOS()
      subrhs.killPOS()
      simpl.addStep(sublhs.current + subrhs.current, "Recombine left hand and right hand sides")
      return
    of BEProd:
      # This will distribute the product over any sums

      let sublhs = simpl.addSubstep(exp.lhs, "Simplify left hand side")
      let subrhs = simpl.addSubstep(exp.rhs, "Simplify right hand side")
      sublhs.killPOS()
      subrhs.killPOS()
      var lhs = sublhs.current
      var rhs = subrhs.current
      var temp: BExp

      if rhs.kind == BESum:
        discard
      elif lhs.kind == BESum:
        temp = lhs
        lhs = rhs
        rhs = temp
      else:
        # There's nothing to distribute
        simpl.addStep(lhs * rhs, "Recombine left and right hand sides")
        return

      # now rhs.kind == BESum is guaranteed
      let rrhs = rhs.rhs
      let rlhs = rhs.lhs

      let rrlhs = lhs * rlhs
      let rrrhs = lhs * rrhs

      simpl.addStep(rrlhs + rrrhs, "Distribute " & $lhs & " into " & $rhs)

      let sublhs2 = simpl.addSubstep(rrlhs, "Simplify left hand side")
      let subrhs2 = simpl.addSubstep(rrrhs, "Simplify right hand side")
      sublhs2.killPOS()
      subrhs2.killPOS()
      simpl.addStep(sublhs2.current + subrhs2.current, "Recombine left and right hand sides")

proc simplifyProduct(simpl: BExpSimplifier)
proc simplifySum(simpl: BExpSimplifier)
proc simplifySumStep(simpl: BExpSimplifier): bool
proc pruneImpliedTerms(simpl: BExpSimplifier)

proc simplify*(simpl: BExpSimplifier, prune = true) =
  simpl.killPOS()

  let sopexp = simpl.current

  case sopexp.kind:
    of BEVar, BETrue, BEFalse:
      discard
    of BENot:
      let subnot = simpl.addSubstep(sopexp.exp, "Simplify under NOT")
      subnot.simplify()
      simpl.addStep(-subnot.current, "Put expression back under NOT")
    of BEProd:
      simpl.simplifyProduct()
    of BESum:
      simpl.simplifySum()

  if prune:
    simpl.pruneImpliedTerms()

proc simplifySum(simpl: BExpSimplifier) =
  let exp = simpl.current

  # recursively collect terms
  var terms = collectSumTerms(exp)

  # first pass: simplify, return true if a term is true, remove false terms
  for index, term in terms:
    # simplify
    let subterm = simpl.addSubstep(term, "Simplify term of sum")
    subterm.simplify()
    terms[index] = subterm.current
    simpl.addStep(sum(terms), "Recombine simplified term")

    if terms[index].kind == BETrue:
      simpl.addStep(term, "If TRUE appears in a sum, whole result is true")
      return

  terms = deduplicate(terms)
  simpl.addStep(sum(terms), "Remove duplicate terms")

  filterFalseTerms(terms)
  simpl.addStep(sum(terms), "Remove false terms")


  # second pass: check for x + x'
  for index1, term1 in terms:
    for index2, term2 in terms:
      if index1 != index2:
        if term1.kind == BENot:
          if term2 == term1.exp:
            terms[index1] = BTrue
            terms[index2] = BTrue
        if term2.kind == BENot:
          if term1 == term2.exp:
            terms[index1] = BTrue
            terms[index2] = BTrue


  filterTrueTerms(terms)
  var newExp = sum(terms)
  if newExp == BFalse:
    newExp = BTrue
  simpl.addStep(newExp, "Remove a + a' terms")

  var success = true

  while success:
    success = simpl.simplifySumStep()

# IMPORTANT: assumes it's not a POS, rather just product of other products
# (or just two variables)
proc simplifyProduct(simpl: BExpSimplifier) =
  let exp = simpl.current

  # recursively collect terms
  var terms = collectProdTerms(exp)

  # first pass: simplify, return false if a term is false, remove true terms
  for index, term in terms:
    # simplify
    let subterm = simpl.addSubstep(term, "Simplify term of product")
    subterm.simplify()
    terms[index] = subterm.current
    simpl.addStep(product(terms), "Recombine simplified term")
    if terms[index].kind == BEFalse:
      simpl.addStep(term, "If a product contains FALSE, its value is FALSE")
      return
    if terms[index].kind == BETrue:
      terms.delete(index)

  terms = deduplicate(terms)
  simpl.addStep(product(terms), "Remove TRUE terms and duplicates from product")

  # second pass: check for aa'
  for index1, term1 in terms:
    for index2, term2 in terms:
      if index1 != index2:
        if term1.kind == BENot:
          if term2 == term1.exp:
            simpl.addStep(BFalse, "If a product has a term and its complement, it is FALSE")
            return
        if term2.kind == BENot:
          if term1 == term2.exp:
            simpl.addStep(BFalse, "If a product has a term and its complement, it is FALSE")
            return

  simpl.addStep(product(terms), "Remove terms if their complement is also there")

proc simplifySumStep(simpl: BExpSimplifier): bool =
  let exp = simpl.current

  if exp.kind != BESum:
    return false

  var terms = collectSumTerms(exp)
  filterFalseTerms(terms)

  for index1, term1 in terms:
    for index2, term2 in terms:
      if index1 != index2:
        var terms1 = collectProdTerms(term1)
        var terms2 = collectProdTerms(term2)
        var commonTerms: seq[BExp]
        newSeq(commonTerms, 0)

        for pindex1, pterm1 in terms1:
          for pindex2, pterm2 in terms2:
            if pterm1 == pterm2:
              terms1.delete(pindex1)
              terms2.delete(pindex2)
              commonTerms.add(pterm1)

        if commonTerms.len > 0:
          let outside = product(commonTerms)
          let inside = product(terms1) + product(terms2)
          let subinside = newBExpSimplifier(inside)
          subinside.simplify()
          let insideSimplified = subinside.current

          if inside == insideSimplified:
            continue
          else:
            terms[index1] = BFalse
            terms[index2] = BFalse
            filterFalseTerms(terms)
            terms.add(outside * inside)
            simpl.addStep(sum(terms), "Factor out common terms")
            simpl.addSubstep(subinside, "Simplify the inside part")
            discard terms.pop()

            terms.add(outside * insideSimplified)
            simpl.addStep(sum(terms), "Recombine simplified inside")

            let newTerm = terms.pop()
            let subnt = simpl.addSubstep(newTerm, "Simplify factored term")
            subnt.simplify()
            terms.add(collectSumTerms(subnt.current))


            # collectSumTerms(simplify(outside * insideSimplified))

            simpl.addStep(sum(terms), "Recombine simplified factored term")
            return true
  return false

# constraint is a list of variables (or negative variables)
# term is also that
proc checkConstraint(constraint, term: seq[BExp]): bool =
  for cterm in constraint:
    for tterm in term:
      if cterm == -tterm or -cterm == tterm:
        return false

  return true

# constraints is a list of PRODUCTS of variables (or negative variables)
# term is a list of variables (or negative variables)
proc checkImplication(constraints, term: seq[BExp]): bool =
  result = false
  for constraint in constraints:
    result = result or checkConstraint(collectProdTerms(constraint), term)

proc collectCommonTerms(terms: seq[seq[BExp]]): seq[BExp] =
  var common, extra: seq[BExp]
  newSeq(common, 0)
  newSeq(extra, 0)

  for index in low(terms)+1..high(terms):
    let term = terms[index]
    let prevTerm = terms[index-1]
    setCompare(term, prevTerm, common, extra)

  return common

proc pruneImpliedTerms(simpl: BExpSimplifier) =
  let exp = simpl.current
  if exp.kind != BESum:
    return

  var terms = collectSumTerms(exp)

  var termsToDelete: seq[int]
  newSeq(termsToDelete, 0)

  for index, deleted in terms:
    let checkTerm = terms[index]
    var termscopy = terms
    termscopy.delete(index)

    let simpltc = newBExpSimplifier(-sum(termscopy))
    simpltc.simplify(false)
    let constraintExp = simpltc.current
    let constraints = collectSumTerms(constraintExp)

    var checkTermPTerms = collectProdTerms(checkTerm)

    if checkImplication(constraints, checkTermPTerms):
      # The term can't be deleted but maybe some of its parts can
      let guaranteedTrue = collectCommonTerms(constraints.map(collectProdTerms) & checkTermPTerms)
      if guaranteedTrue.len > 0:
        var index2 = checkTermPTerms.len()
        while index2 > 0:
          dec index2
          if checkTermPTerms[index2] in guaranteedTrue:
            checkTermPTerms[index2] = BTrue

        let newProduct = product(checkTermPTerms)
        let prodsimpl = newBExpSimplifier(newProduct)
        prodsimpl.simplifyProduct()
        terms[index] = prodsimpl.current
        simpl.addStep(sum(terms), "Remove terms guaranteed to be true")
    else:
      termsToDelete.add(index)

  var index = termsToDelete.len
  while index > 0:
    dec index
    let indexToDelete = termsToDelete[index]
    let deletedTerm = terms[indexToDelete]
    terms.delete(indexToDelete)
    simpl.addStep(sum(terms), "Remove term " & $deletedTerm)

  simpl.simplifySum()

proc simplifyFull*(exp: BExp): BExp =
  let simpl = newBExpSimplifier(exp)
  simpl.simplify()

  return simpl.current

when isMainModule:
  import boolexpparser
  import os

  let simpl = newBExpSimplifier(parse(paramStr(1)))
  simpl.simplify()
  simpl.pruneUselessSteps()
  newFileStream(stdout).write(simpl)
