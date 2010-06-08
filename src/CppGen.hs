module CppGen(handleHeader)
where

import System.FilePath
import System.IO
import Data.List
import Data.Maybe
import Control.Monad
import Text.Printf
import qualified Data.Set as S

import Text.Regex.Posix
import Safe

import HeaderData
import CppUtils
import Utils

publicMemberFunction :: Object -> Bool
publicMemberFunction (FunDecl _ _ _ _ (Just (Public, _)) _ _) = True
publicMemberFunction _                                      = False

showP (ParamDecl pn pt _ _) = pt ++ " " ++ pn

paramFormat :: [ParamDecl] -> String
paramFormat (p1:p2:ps) = showP p1 ++ ", " ++ paramFormat (p2:ps)
paramFormat [p1]       = showP p1
paramFormat []         = ""

-- separate pointer * from other chars.
-- remove keywords such as virtual, static, etc.
correctParam :: ParamDecl -> ParamDecl
correctParam p = p{vartype = correctType (vartype p)} -- TODO: arrays?

refToPointerParam :: ParamDecl -> ParamDecl
refToPointerParam p = p{vartype = refToPointer (vartype p)}

refToPointer :: String -> String
refToPointer t = 
  if last t == '&'
    then init t ++ "*"
    else t

-- separate pointer * from other chars.
-- remove keywords such as virtual, static, etc.
correctType :: String -> String
correctType t =
  let ns = words t
  in case ns of
       []  -> ""
       ms  -> intercalate " " $ sepChars "*" $ filter isType ms

sepChars :: String -> [String] -> [String]
sepChars st = map (sepChar st)

sepChar :: String -> String -> String
sepChar st (x:y:xs)    = if x /= ' ' && x `notElem` st && y `elem` st
                           then x {-: ' '-} : sepChar st (y:xs)
                           else x : sepChar st (y:xs)
sepChar _  l           = l

isType :: String -> Bool
isType "virtual" = False
isType "static"  = False
isType "enum"    = False
-- isType "const"   = False
isType "mutable" = False
isType "struct"  = False
isType "union"   = False
isType "inline"  = False
isType _         = True

handleHeader :: FilePath -> [FilePath] -> [String] -> [String] -> [(String, String)] -> FilePath -> [Object] -> IO ()
handleHeader outdir incfiles exclclasses excls rens headername objs = do
    withFile outfile WriteMode $ \h -> do
        hPrintf h "#ifndef CGEN_%s_H\n" (toCapital (takeBaseName headername))
        hPrintf h "#define CGEN_%s_H\n" (toCapital (takeBaseName headername))
        hPrintf h "\n"
        forM_ incfiles $ \inc -> do
            hPrintf h "#include <%s>\n" inc
        hPrintf h "\n"
        hPrintf h "extern \"C\"\n"
        hPrintf h "{\n"
        -- hPrintf h "#ifndef CGEN_OUTPUT_INTERN\n"
        -- hPrintf h "\n"
        -- forM_ classnames $ \cl -> do
            -- hPrintf h "struct %s;\n" cl
        -- hPrintf h "\n"
        -- hPrintf h "#else\n"
        hPrintf h "\n"
        forM_ namespaces $ \ns -> do
            hPrintf h "using namespace %s;\n" ns
        hPrintf h "\n"
        forM_ typedefs $ \(td1, td2) -> do
            hPrintf h "typedef %s %s;\n" td1 td2
        -- hPrintf h "\n"
        -- hPrintf h "#endif\n"
        hPrintf h "\n"
        forM_ funs $ \fun -> do
            hPrintf h "%s %s(%s);\n" 
                (rettype fun) 
                (funname fun) 
                (paramFormat (params fun))
        hPrintf h "\n"
        hPrintf h "}\n"
        hPrintf h "\n"
        hPrintf h "#endif\n"
        hPrintf h "\n"
        hPutStrLn stderr $ "Wrote file " ++ outfile

    withFile cppoutfile WriteMode $ \h -> do
        hPrintf h "#define CGEN_OUTPUT_INTERN\n"
        hPrintf h "#include \"%s\"" headername
        hPrintf h "\n"
        forM_ (zip funs allfuns) $ \(fun, origfun) -> do
            hPrintf h "%s %s(%s)\n" 
                (rettype fun)
                (funname fun)
                (paramFormat (params fun))
            hPrintf h "{\n"
            -- NOTE: do NOT call refToPointerParam or correctFuncParams
            -- for prs, because then the information that the parameter
            -- is actually a reference and the pointer must be dereferenced
            -- is lost.
            let prs = intercalate ", " $ map correctRef $ checkParamNames $ map correctParam $ params origfun
            switch (funname origfun)
              [(getClname origfun,      hPrintf h "    return new %s(%s);\n" (stripConst . stripPtr $ rettype fun) prs),
               ('~':getClname origfun,  hPrintf h "    delete this_ptr;\n")]
              (if rettype fun == "void" 
                 then hPrintf h "    this_ptr->%s(%s);\n" (funname origfun) prs
                 else hPrintf h "    return this_ptr->%s(%s);\n" (funname origfun) prs)
            hPrintf h "}\n"
            hPrintf h "\n"
        hPutStrLn stderr $ "Wrote file " ++ cppoutfile

  where outfile    = (outdir </> headername)
        cppoutfile = (outdir </> takeBaseName headername <.> "cpp")
        allfuns    = filter (\f -> publicMemberFunction f && 
                                   not (abstract f) && 
                                   not (excludeFun f) && 
                                   not (abstractConstructor classes f)) (getFuns objs)
        namespaces = filter (not . null) $ nub $ map (headDef "") (map fnnamespace funs)
        -- list of names of all parsed classes
        classnames = filter (not . null) $ nub $ map getObjName $ getClasses objs
        classes    = concatMap (\nm -> filter (classHasName nm) (getClasses objs)) classnames
        alltypedefs = catMaybes $ map getTypedef (map snd $ concatMap classobjects classes)
        usedtypedefs = usedTypedefs usedtypes alltypedefs
        extratypedefs = extraTypedefs usedtypedefs alltypedefs
        -- NOTE: can't just use only public typedefs, because they sometimes depend on 
        -- protected typedefs, so include them as well (so-called secondary typedefs).
        typedefs   = nub $ extratypedefs ++ usedtypedefs
        allenums   = map snd $ filter (\(v, o) -> isEnum o && v == Public) $ concatMap classobjects classes
        funs       = mangle $ map expandFun allfuns
        excludeFun f = lastDef ' ' (correctType $ rettype f) == '&' || -- TODO: allow returned references
                       or (map (\e -> funname f =~ e) excls) ||
                       or (map (\e -> fromMaybe "" (liftM snd (fnvisibility f)) =~ e) exclclasses) ||
                       take 8 (funname f) == "operator"  -- TODO: allow normal functions with name starting with operator
        expandFun f = addConstness . -- add const keyword if the function is const
                      renameTypes rens . -- rename types as specified by user
                      addClassspaces allenums classes . -- add qualification when necessary
                      correctFuncRetType . -- remove keywords from return type
                      correctFuncParams . -- ref to pointer, create param name if none, remove keywords
                      finalName . -- expand function name by class and namespace
                      addThisPointer .  -- 1st parameter
                      extendFunc $ f -- constructor & destructor handling
        usedtypes  = getAllTypes funs

renameTypes :: [(String, String)] -> Object -> Object
renameTypes rens f@(FunDecl _ rt ps _ _ _ _) =
    f{rettype = renameType rens rt,
      params = map (renameParam rens) ps}
renameTypes _ n = n

renameParam :: [(String, String)] -> ParamDecl -> ParamDecl
renameParam rens p@(ParamDecl _ pt _ _) =
    p{vartype = renameType rens pt}

renameType :: [(String, String)] -> String -> String
renameType rens t =
  let mnt = lookup tm rens
      tm = (stripConst . stripPtr) t
      mf1 = if isConst t then makeConst else id
      mf2 = makePtr (isPtr t)
      nt = case mnt of
             Nothing -> if '<' `elem` t && '>' `elem` t
                          then handleTemplateTypes rens t
                          else tm
             Just t' -> t'
  in (mf1 . mf2) nt

handleTemplateTypes :: [(String, String)] -> String -> String
handleTemplateTypes rens t = 
  let alltypes = typesInType t
      newtypes = map (renameType rens) alltypes
  in foldr (uncurry replace) ((stripConst . stripPtr) t) (zip alltypes newtypes)

makeConst :: String -> String
makeConst n = "const " ++ n

makePtr :: Int -> String -> String
makePtr num t = t ++ replicate num '*'

isPtr :: String -> Int
isPtr = length . filter (=='*') . dropWhile (/= '*')

abstractConstructor :: [Object] -> Object -> Bool
abstractConstructor classes (FunDecl fn _ _ _ (Just (_, _)) _ _) =
  case fetchClass classes fn of
    Nothing -> False
    Just cl -> any isAbstractFun (map snd $ classobjects cl)
abstractConstructor _       _                                  = False

-- typesInType "const int" = ["int"]
-- typesInType "map<String, Animation*>::type" = ["String", "Animation"]
typesInType :: String -> [String]
typesInType v =
    case betweenAngBrackets v of
      "" -> [(stripConst . stripPtr) v]
      n  -> map (stripConst . stripPtr) $ splitBy ',' n

extraTypedefs :: [(String, String)] -> [(String, String)] -> [(String, String)]
extraTypedefs ts = filter (extractSecType ts)

extractSecType :: [(String, String)] -> (String, String) -> Bool
extractSecType ts (_, t2) = 
  let sectypes = typesInType t2
      tsstypes = concatMap typesInType (map fst ts)
  in (any (`elem` tsstypes) sectypes)

-- for all types of a function, turn "y" into "x::y" when y is a nested class inside x.
addClassspaces :: [Object] -> [Object] -> Object -> Object
addClassspaces enums classes f@(FunDecl _ rt ps _ _ _ _) =
  let rt' = addClassQual enums classes rt
      ps' = map (addParamClassQual enums classes) ps
  in f{rettype = rt',
       params  = ps'}
addClassspaces _     _       n                         = n

addParamClassQual :: [Object] -> [Object] -> ParamDecl -> ParamDecl
addParamClassQual enums classes p@(ParamDecl _ t _ _) =
  let t' = addClassQual enums classes t
  in p{vartype = t'}

-- add class qualification to rt, if a class named rt is found.
-- the qualification added is the class nesting of the found class.
addClassQual :: [Object] -> [Object] -> String -> String
addClassQual enums classes rt =
  case fetchClass classes ((stripConst . stripPtr) rt) of
    Nothing -> case fetchEnum enums ((stripConst . stripPtr) rt) of
                 Nothing -> rt
                 Just e  -> addNamespaceQual (map snd $ enumclassnesting e) rt
    Just c  -> addNamespaceQual (map snd $ classnesting c) rt

-- addNamespaceQual ["aa", "bb"] "foo" = "bb::aa::foo"
addNamespaceQual :: [String] -> String -> String
addNamespaceQual ns n = concatMap (++ "::") ns ++ n

-- turn a "char& param" into "*param".
correctRef :: ParamDecl -> String
correctRef (ParamDecl nm pt _ _) =
  if '&' `elem` take 2 (reverse pt)
    then '*':nm
    else nm

-- change ref to pointer and separate pointer * from other chars for all params.
-- if param has no name, create one.
-- remove keywords such as virtual, static, etc.
correctFuncParams :: Object -> Object
correctFuncParams f@(FunDecl _ _ ps _ _ _ _) = 
  f{params = checkParamNames (map (correctParam . refToPointerParam) ps)}
correctFuncParams n                                 = n

-- for each unnamed parameter,
-- create a parameter name of (type) ++ running index.
checkParamNames :: [ParamDecl] -> [ParamDecl]
checkParamNames = go (1 :: Int)
  where go _ []     = []
        go n (p:ps) =
          let (p', n') = case varname p of
                           "" -> (p{varname = (stripConst . stripPtr $ vartype p) ++ (show n)}, n + 1)
                           _  -> (p, n)
          in p':(go n' ps)

-- expand function name by namespace and class name.
finalName :: Object -> Object
finalName f@(FunDecl fname _ _ funns _ _ _) =
  let clname = getClname f
      nsname = headDef "" funns
      updname = nsname ++ (if not (null nsname) then "_" else "") ++ 
                clname ++ (if not (null clname) then "_" else "") ++ fname
  in f{funname = updname}
finalName n = n

constructorName, destructorName :: String
constructorName = "new"
destructorName = "delete"

addThisPointer :: Object -> Object
addThisPointer f@(FunDecl fname _ ps _ (Just (_, clname)) _ _)
  | fname == constructorName = f
  | otherwise
    = f{params = (t:ps)}
      where t = ParamDecl this_ptrName (clname ++ "*") Nothing Nothing
addThisPointer n = n

this_ptrName = "this_ptr"

-- correct constructors and destructors.
extendFunc :: Object -> Object
extendFunc f@(FunDecl fname _ _ _ (Just (_, clname)) _ _) 
  | fname == clname = f{funname = constructorName,
                        rettype = fname ++ " *"}
  | fname == '~':clname = f{funname = destructorName,
                            rettype = "void"}
  | otherwise           = f
extendFunc n = n

-- const keyword to return value and this_ptr if needed.
addConstness :: Object -> Object
addConstness f@(FunDecl _ fr ps _ _ constfunc _)
  = f{rettype = cident fr,
      params = map cidentP ps}
      where cident  v = if not (isConst v) && 
                           constfunc && 
                           '*' `elem` v 
                          then "const " ++ v 
                          else v
            cidentP p = let n = if not (isConst (varname p)) &&
                                   constfunc && 
                                   varname p == this_ptrName
                                  then "const " ++ vartype p
                                  else vartype p
                        in p{vartype = n}
addConstness n = n

-- "aaa < bbb, ddd> fff" = " bbb, ddd"
betweenAngBrackets :: String -> String
betweenAngBrackets = fst . foldr go ("", Nothing)
  where go _   (accs, Just True)  = (accs, Just True)    -- done
        go '>' (accs, Nothing)    = (accs, Just False)   -- start
        go '<' (accs, Just False) = (accs, Just True)    -- finish
        go c   (accs, Just False) = (c:accs, Just False) -- collect
        go _   (accs, Nothing)    = (accs, Nothing)      -- continue

-- filtering typedefs doesn't help - t1 may refer to private definitions.
usedTypedefs :: S.Set String -> [(String, String)] -> [(String, String)]
usedTypedefs s = filter (\(_, t2) -> t2 `S.member` s)

-- separate pointer * from other chars in function return type.
-- remove keywords such as virtual, static, etc.
correctFuncRetType :: Object -> Object
correctFuncRetType f@(FunDecl _ fr _ _ _ _ _)
  = f{rettype = correctType fr}
correctFuncRetType n = n

-- o(n).
mangle :: [Object] -> [Object]
mangle []     = []
mangle (n:ns) = 
  let num = length $ filter (== funname n) $ map funname ns
      m   = n{funname = funname n ++ show num}
  in if num == 0
       then n : mangle ns
       else m : mangle ns
