{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Typst.Evaluate
  ( evaluateTypst,
    valToContent,
  )
where

import Control.Monad (MonadPlus (mplus), foldM, foldM_)
import Control.Monad.State (MonadTrans (lift))
import qualified Data.ByteString as BS
import Data.List (intersperse, sortOn)
import qualified Data.Map as M
import qualified Data.Map.Ordered as OM
import Data.Maybe (isJust)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import System.FilePath (replaceFileName, takeBaseName)
import Text.Parsec
import Typst.Bind (destructuringBind)
import Typst.Methods (getMethod)
import Typst.Module.Standard (loadFileText, standardModule)
import Typst.Parse (parseTypst)
import Typst.Regex (match)
import Typst.Show (applyShowRules)
import Typst.Syntax
import Typst.Types
import Typst.Util (makeFunction, nthArg)
import Data.Time (UTCTime)

-- import Debug.Trace

-- | Evaluate a parsed typst expression, evaluating the code and
-- replacing it with content.
evaluateTypst ::
  Monad m =>
  -- | Function to read a file
  (FilePath -> m BS.ByteString) ->
  -- | Function to get current UTCTime
  m UTCTime ->
  -- | Path of parsed content
  FilePath ->
  -- | Markup produced by 'parseTypst'
  [Markup] ->
  m (Either ParseError (Seq Content))
evaluateTypst loadBytes currentUTCTime =
  runParserT
    (mconcat <$> many pContent <* eof)
    initialEvalState { evalLoadBytes = loadBytes
                     , evalCurrentUTCTime = currentUTCTime}

initialEvalState :: EvalState m
initialEvalState =
  emptyEvalState { evalIdentifiers = [(BlockScope, standardModule')] }
  where
    standardModule' = M.insert "eval" evalFunction standardModule
    evalFunction = makeFunction $ do
      code :: Text <- nthArg 1
      case parseTypst "eval" ("#{\n" <> code <> "\n}") of
        Left e -> fail $ "eval: " <> show e
        Right [Code _ expr] ->
          -- run in Either monad so we can't access file system
          case runParserT (evalExpr expr) initialEvalState "eval" [] of
            Failure e -> fail $ "eval: " <> e
            Success (Left e) -> fail $ "eval: " <> show e
            Success (Right val) -> pure val
        Right _ -> fail "eval: got something other than Code (should not happen)"

satisfyTok :: Monad m => (Markup -> Bool) -> MP m Markup
satisfyTok f = tokenPrim show showPos match'
  where
    showPos _oldpos (Code pos _) _ = pos
    showPos oldpos _ _ = oldpos
    match' x | f x = Just x
    match' _ = Nothing

pContent :: Monad m => MP m (Seq Content)
pContent = (pTxt <|> pElt) >>= applyShowRules >>= addTextElement

addTextElement :: Monad m => Seq Content -> MP m (Seq Content)
addTextElement = foldM go mempty
  where
    go acc (Txt "") = pure acc
    go acc (Txt t) = (acc <>) <$> element "text" (Arguments [VContent [Txt t]] OM.empty)
    go acc x = pure (acc Seq.|> x)

isText :: Markup -> Bool
isText Text {} = True
isText Space = True
isText SoftBreak = True
isText Nbsp = True
isText Shy = True
isText EmDash = True
isText EnDash = True
isText Ellipsis = True
isText (Quote _) = True
isText _ = False

getText :: Markup -> Text
getText (Text t) = t
getText Space = " "
getText SoftBreak = "\n"
getText Nbsp = "\xa0"
getText Shy = "\xad"
getText EmDash = "\x2014"
getText EnDash = "\x2013"
getText Ellipsis = "\x2026"
getText (Quote c) = T.singleton c -- TODO localize
getText _ = ""

pTxt :: Monad m => MP m (Seq Content)
pTxt = do
  mathMode <- evalMath <$> getState
  txt <-
    if mathMode
      then getText <$> satisfyTok isText
      else mconcat . map getText . setQuotes <$> many1 (satisfyTok isText)
  pure $ Seq.singleton $ Txt txt

setQuotes :: [Markup] -> [Markup]
setQuotes [] = []
setQuotes (Quote '"' : x : rest)
  | x == Space || x == SoftBreak = Quote '\x201D' : setQuotes (x : rest)
setQuotes (Quote '\'' : x : rest)
  | x == Space || x == SoftBreak = Quote '\x201D' : setQuotes (x : rest)
setQuotes (x : Quote '"' : rest)
  | x == Space || x == SoftBreak = x : Quote '\x201C' : setQuotes rest
setQuotes (x : Quote '\'' : rest)
  | x == Space || x == SoftBreak = x : Quote '\x2018' : setQuotes rest
setQuotes (Text t1 : Quote '\'' : Text t2 : rest) =
  Text t1 : Quote '\x2019' : setQuotes (Text t2 : rest)
setQuotes (Quote '"' : Text t : rest)
  | t `notElem` ([")", ".", ",", ";", ":", "?", "!", "]"] :: [Text]) =
      Quote '\x201C' : setQuotes (Text t : rest)
setQuotes (Quote '\'' : Text t : rest)
  | t `notElem` ([")", ".", ",", ";", ":", "?", "!", "]"] :: [Text]) =
      Quote '\x2018' : setQuotes (Text t : rest)
setQuotes (Quote '"' : rest) = Quote '\x201D' : setQuotes rest
setQuotes (Quote '\'' : rest) = Quote '\x2019' : setQuotes rest
setQuotes (x : xs) = x : setQuotes xs

pInnerContents :: Monad m => [Markup] -> MP m (Seq Content)
pInnerContents ms = do
  oldInput <- getInput
  oldPos <- getPosition
  oldShowRules <- evalShowRules <$> getState
  setInput ms
  result <- mconcat <$> (many pContent <* eof)
  setInput oldInput
  setPosition oldPos
  updateState $ \st -> st {evalShowRules = oldShowRules}
  pure result

single :: Content -> Seq Content
single = Seq.singleton

applyElementFunction :: Monad m => Identifier -> Function -> Arguments -> MP m Val
applyElementFunction name (Function f) args = do
  -- lookup styles set by "set" and apply them as defaults:
  mbSty <- M.lookup name . evalStyles <$> getState
  f $ maybe args (<> args) mbSty

element :: Monad m => Identifier -> Arguments -> MP m (Seq Content)
element name@(Identifier n) args = do
  eltfn <- lookupIdentifier name
  case eltfn of
    VFunction Nothing _ (Function f) -> valToContent <$> f args
    VFunction (Just i) _ (Function f) ->
      valToContent <$> applyElementFunction i (Function f) args
    _ -> fail $ T.unpack n <> " is not an element function"

pElt :: Monad m => MP m (Seq Content)
pElt = do
  tok <- satisfyTok (not . isText)
  case tok of
    ParBreak -> element "parbreak" mempty
    HardBreak -> element "linebreak" mempty
    Comment -> pure mempty
    Code pos expr -> setPosition pos *> pExpr expr
    Emph ms -> do
      body <- pInnerContents ms
      element "emph" Arguments {positional = [VContent body], named = OM.empty}
    Strong ms -> do
      body <- pInnerContents ms
      element "strong" Arguments {positional = [VContent body], named = OM.empty}
    Bracketed ms -> do
      body <- pInnerContents ms
      pure $ (Txt "[" Seq.<| body) Seq.|> Txt "]"
    RawBlock lang txt ->
      element
        "raw"
        Arguments
          { positional = [VString txt],
            named =
              OM.fromList
                [ ("block", VBoolean True),
                  ( "lang",
                    if T.null lang
                      then VNone
                      else VString lang
                  )
                ]
          }
    RawInline txt -> do
      element
        "raw"
        Arguments
          { positional = [VString txt],
            named =
              OM.fromList
                [ ("lang", VNone),
                  ("block", VBoolean False)
                ]
          }
    Heading level ms -> do
      content <- pInnerContents ms
      element
        "heading"
        Arguments
          { positional = [VContent content],
            named =
              OM.fromList
                [("level", VInteger (fromIntegral level))]
          }
    Equation display ms -> inBlock BlockScope $ do
      VModule _ mathmod <- lookupIdentifier "math"
      importModule mathmod
      VModule _ symmod <- lookupIdentifier "sym"
      importModule symmod
      oldMath <- evalMath <$> getState
      updateState $ \st -> st {evalMath = True}
      content <- pInnerContents ms
      updateState $ \st -> st {evalMath = oldMath}
      element
        "equation"
        Arguments
          { positional = [VContent content],
            named =
              OM.fromList
                [ ("block", VBoolean display),
                  ("numbering", VNone)
                ]
          }
    MFrac numexp denexp -> do
      let handleParens (MGroup (Just "(") (Just ")") xs) = MGroup Nothing Nothing xs
          handleParens x = x
      num <- pInnerContents [handleParens numexp]
      den <- pInnerContents [handleParens denexp]
      element
        "frac"
        Arguments
          { positional = [VContent num, VContent den],
            named = OM.empty
          }
    MAttach mbBottomExp mbTopExp baseExp -> do
      base <- pInnerContents [baseExp]
      mbBottom <-
        maybe
          (pure Nothing)
          (fmap Just . pInnerContents . (: []))
          mbBottomExp
      mbTop <-
        maybe
          (pure Nothing)
          (fmap Just . pInnerContents . (: []))
          mbTopExp
      element
        "attach"
        Arguments
          { positional = [VContent base],
            named =
              OM.fromList
                [ ("b", maybe VNone VContent mbBottom),
                  ("t", maybe VNone VContent mbTop)
                ]
          }
    MGroup mbOp mbCl ms -> wrapIn mbOp mbCl <$> pInnerContents ms
    MAlignPoint -> element "alignpoint" mempty
    Ref ident supp -> do
      supp' <- evalExpr supp
      element
        "ref"
        Arguments
          { positional = [VLabel ident],
            named =
              OM.fromList
                [ ( "supplement", supp' ) ]
          }
    BulletListItem ms -> do
      skipMany $ satisfyTok isBreak
      firstItem <- pInnerContents ms
      -- parse a sequence of list items and put them in a list element
      items <- (firstItem :) <$> many pListItem
      element
        "list"
        Arguments
          { positional = map VContent items,
            named = OM.empty
          }
    EnumListItem mbStart ms -> do
      skipMany $ satisfyTok isBreak
      firstItem <- pInnerContents ms
      -- parse a sequence of list items and put them in a list element
      items <- (firstItem :) <$> many pEnumItem
      element
        "enum"
        Arguments
          { positional = map VContent items,
            named =
              maybe
                OM.empty
                ( \x ->
                    OM.fromList
                      [("start", VInteger (fromIntegral x))]
                )
                mbStart
          }
    DescListItem ts ds -> do
      ts' <- pInnerContents ts
      ds' <- pInnerContents ds
      skipMany (satisfyTok isBreak)
      let firstItem = VArray [VContent ts', VContent ds']
      items <- (firstItem :) <$> many pDescItem
      element
        "terms"
        Arguments
          { positional = items,
            named = OM.empty
          }
    Url t ->
      element
        "link"
        Arguments
          { positional =
              [ VString t,
                VContent (Seq.singleton (Txt t))
              ],
            named = OM.empty
          }
    _ -> fail $ "Encountered " <> show tok <> " in pElt"

pDescItem :: Monad m => MP m Val
pDescItem = do
  tok <- satisfyTok isDescListItem
  case tok of
    DescListItem ts ds -> do
      ts' <- pInnerContents ts
      ds' <- pInnerContents ds
      skipMany (satisfyTok isBreak)
      pure $ VArray [VContent ts', VContent ds']
    _ -> fail "pDescItem encountered non DescListItem"
  where
    isDescListItem DescListItem {} = True
    isDescListItem _ = False

pEnumItem :: Monad m => MP m (Seq Content)
pEnumItem = do
  tok <- satisfyTok isEnumListItem
  case tok of
    EnumListItem _ ms -> pInnerContents ms <* skipMany (satisfyTok isBreak)
    _ -> fail "pEnumItem encountered non EnumListItem"
  where
    isEnumListItem EnumListItem {} = True
    isEnumListItem _ = False

pListItem :: Monad m => MP m (Seq Content)
pListItem = do
  tok <- satisfyTok isBulletListItem
  case tok of
    BulletListItem ms -> pInnerContents ms <* skipMany (satisfyTok isBreak)
    _ -> fail "pListItem encountered non BulletListItem"
  where
    isBulletListItem BulletListItem {} = True
    isBulletListItem _ = False

isBreak :: Markup -> Bool
isBreak SoftBreak = True
isBreak ParBreak = True
isBreak _ = False

wrapIn :: Maybe Text -> Maybe Text -> Seq Content -> Seq Content
wrapIn Nothing Nothing cs = cs
wrapIn (Just op) (Just cl) cs =
  Seq.singleton $
    Elt
      "math.lr"
      Nothing
      [ ( "body",
          VArray $
            V.fromList
              [VContent $ Txt op Seq.<| (cs Seq.|> Txt cl)]
        )
      ]
wrapIn Nothing (Just cl) cs = cs Seq.|> Txt cl
wrapIn (Just op) Nothing cs = Txt op Seq.<| cs

pExpr :: Monad m => Expr -> MP m (Seq Content)
pExpr expr = valToContent <$> evalExpr expr

evalExpr :: Monad m => Expr -> MP m Val
evalExpr expr =
  case expr of
    Literal lit -> pure $ evalLiteral lit
    Group e -> evalExpr e
    Block (Content ms) -> VContent <$> pInnerContents ms
    Block (CodeBlock exprs) ->
      inBlock BlockScope $
        -- let, etc. inside block are isolated
        -- we concat the results inside the block
        fst
          <$> foldM
            ( \(result, finished) e ->
                if finished
                  then pure (result, finished)
                  else do
                    updateState $ \st -> st {evalFlowDirective = FlowNormal}
                    val <- evalExpr e
                    flow <- evalFlowDirective <$> getState
                    case flow of
                      FlowNormal -> do
                        combined <- joinVals result val
                        pure (combined, False)
                      FlowContinue -> do
                        combined <- joinVals result val
                        pure (combined, True)
                      FlowBreak -> do
                        combined <- joinVals result val
                        pure (combined, True)
                      FlowReturn True -> pure (val, True)
                      FlowReturn False -> do
                        combined <- joinVals result val
                        pure (combined, True)
            )
            (VNone, False)
            exprs
    Array e -> VArray . V.fromList <$> mapM evalExpr e
    Dict items ->
      VDict
        <$> foldM
          ( \m (k, e) -> do
              val <- evalExpr e
              pure $ m OM.|> (k, val)
          )
          OM.empty
          items
    Not e -> do
      val <- evalExpr e
      case val of
        VBoolean b -> pure $ VBoolean (not b)
        _ -> fail $ "Cannot apply 'not' to " <> show val
    And e1 e2 -> do
      val1 <- evalExpr e1
      case val1 of
        VBoolean False -> pure $ VBoolean False
        VBoolean True -> do
          val2 <- evalExpr e2
          case val2 of
            VBoolean True -> pure $ VBoolean True
            VBoolean False -> pure $ VBoolean False
            _ -> fail $ "Cannot apply 'and' to " <> show val1
        _ -> fail $ "Cannot apply 'and' to " <> show val1
    Or e1 e2 -> do
      val1 <- evalExpr e1
      case val1 of
        VBoolean True -> pure $ VBoolean True
        VBoolean False -> do
          val2 <- evalExpr e2
          case val2 of
            VBoolean True -> pure $ VBoolean True
            VBoolean False -> pure $ VBoolean False
            _ -> fail $ "Cannot apply 'or' to " <> show val1
        _ -> fail $ "Cannot apply 'or' to " <> show val1
    Ident ident -> lookupIdentifier ident
    Let bind e -> do
      val <- evalExpr e
      case bind of
        BasicBind (Just ident) -> addIdentifier ident val
        BasicBind Nothing -> pure ()
        DestructuringBind parts -> destructuringBind addIdentifier parts val
      pure VNone
    LetFunc name params e -> do
      val <- toFunction (Just name) params e
      addIdentifier name val
      pure VNone
    FieldAccess (Ident (Identifier fld)) e -> do
      val <- evalExpr e
      getMethod (updateExpression e) val fld
        <|> case val of
          VSymbol (Symbol _ accent variants) -> do
            let variants' =
                  sortOn (Set.size . fst) $
                    filter (\(var, _) -> fld `Set.member` var) variants
            case variants' of
              [] -> fail $ "Symbol does not have variant " <> show fld
              ((_, s) : _) -> pure $ VSymbol $ Symbol s accent variants'
          VModule _ m ->
            case M.lookup (Identifier fld) m of
              Just x -> pure x
              Nothing -> fail $ "Module does not contain " <> show fld
          VFunction _ m _ ->
            case M.lookup (Identifier fld) m of
              Just x -> pure x
              Nothing -> fail $ "Function scope does not contain " <> show fld
          VDict m ->
            case OM.lookup (Identifier fld) m of
              Just x -> pure x
              Nothing -> fail $ show (Identifier fld) <> " not found"
          _ -> fail "FieldAccess requires a dictionary"
    FieldAccess _ _ -> fail "FieldAccess requires an identifier"
    FuncCall e args -> do
      updateState $ \st -> st {evalFlowDirective = FlowNormal}
      val <- evalExpr e
      mathMode <- evalMath <$> getState
      case val of
        VFunction (Just i) _ (Function f) -> do
          arguments <- toArguments args
          applyElementFunction i (Function f) arguments
        VFunction Nothing _ (Function f) -> toArguments args >>= f
        VSymbol (Symbol _ True _) | mathMode ->
          do
            val' <- lookupIdentifier "accent"
            case val' of
              VFunction _ _ (Function f) ->
                toArguments args
                  >>= f . (\a -> a {positional = positional a ++ [val]})
              _ -> fail "accent not defined"
        _
          | mathMode -> do
              args' <- toArguments args
              pure $
                VContent $
                  valToContent val
                    <> single "("
                    <> mconcat
                      ( intersperse
                          (single ",")
                          (map valToContent (positional args'))
                      )
                    <> single ")"
          | otherwise -> fail "Attempt to call a non-function"
    FuncExpr params e -> toFunction Nothing params e
    Equals e1 e2 -> do
      v1 <- evalExpr e1
      v2 <- evalExpr e2
      case comp v1 v2 of
        Just EQ -> pure $ VBoolean True
        _ -> pure $ VBoolean False
    LessThan e1 e2 -> do
      v1 <- evalExpr e1
      v2 <- evalExpr e2
      case comp v1 v2 of
        Nothing -> fail $ "Can't compare " <> show v1 <> " and " <> show v2
        Just LT -> pure $ VBoolean True
        _ -> pure $ VBoolean False
    GreaterThan e1 e2 -> do
      v1 <- evalExpr e1
      v2 <- evalExpr e2
      case comp v1 v2 of
        Nothing -> fail $ "Can't compare " <> show v1 <> " and " <> show v2
        Just GT -> pure $ VBoolean True
        _ -> pure $ VBoolean False
    LessThanOrEqual e1 e2 -> do
      v1 <- evalExpr e1
      v2 <- evalExpr e2
      case comp v1 v2 of
        Nothing -> fail $ "Can't compare " <> show e1 <> " and " <> show e2
        Just LT -> pure $ VBoolean True
        Just EQ -> pure $ VBoolean True
        _ -> pure $ VBoolean False
    GreaterThanOrEqual e1 e2 -> do
      v1 <- evalExpr e1
      v2 <- evalExpr e2
      case comp v1 v2 of
        Nothing -> fail $ "Can't compare " <> show v1 <> " and " <> show v2
        Just GT -> pure $ VBoolean True
        Just EQ -> pure $ VBoolean True
        _ -> pure $ VBoolean False
    InCollection e1 e2 -> do
      v1 <- evalExpr e1
      v2 <- evalExpr e2
      case v2 of
        VString t ->
          case v1 of
            VString t' -> pure $ VBoolean $ t' `T.isInfixOf` t
            VRegex re -> pure $ VBoolean $ match re t
            _ -> fail $ "Can't apply 'in' to " <> show v1 <> " and string"
        VArray vec -> pure $ VBoolean $ V.elem v1 vec
        VDict m ->
          case v1 of
            VString t -> pure $ VBoolean $ isJust $ OM.lookup (Identifier t) m
            _ -> pure $ VBoolean False
        _ -> fail $ "Can't apply 'in' to " <> show v2
    Negated e -> do
      v <- evalExpr e
      case maybeNegate v of
        Nothing -> fail $ "Can't negate " <> show v
        Just v' -> pure v'
    ToPower e1 e2 -> do
      e <- evalExpr e1
      b <- evalExpr e2
      case (b, e) of
        (VInteger i, VInteger j) ->
          pure $
            VInteger $
              floor ((fromIntegral i :: Double) ** (fromIntegral j :: Double))
        (VInteger i, VRatio j) ->
          pure $
            VFloat ((fromIntegral i :: Double) ** (fromRational j :: Double))
        (VRatio i, VInteger j) ->
          pure $
            VFloat (fromRational i ** (fromIntegral j :: Double))
        (VRatio i, VRatio j) -> pure $ VFloat (fromRational i ** fromRational j)
        (VFloat i, VInteger j) -> pure $ VFloat (i ** (fromIntegral j :: Double))
        (VFloat i, VFloat j) -> pure $ VFloat (i ** j)
        (VInteger i, VFloat j) -> pure $ VFloat ((fromIntegral i :: Double) ** j)
        (VFloat i, VRatio j) -> pure $ VFloat (i ** fromRational j)
        _ -> fail $ "Can't exponentiate " <> show b <> " to " <> show e
    Plus e1 e2 -> do
      v1 <- evalExpr e1
      v2 <- evalExpr e2
      case (v1, v2) of
        (VAlignment x1 y1, VAlignment x2 y2) ->
          pure $ VAlignment (x1 `mplus` x2) (y1 `mplus` y2)
        _ -> case maybePlus v1 v2 of
          Nothing -> fail $ "Can't + " <> show v1 <> " and " <> show v2
          Just v -> pure v
    Minus e1 e2 -> do
      v1 <- evalExpr e1
      v2 <- evalExpr e2
      case maybeMinus v1 v2 of
        Nothing -> fail $ "Can't - " <> show v1 <> " and " <> show v2
        Just v -> pure v
    Times e1 e2 -> do
      v1 <- evalExpr e1
      v2 <- evalExpr e2
      case maybeTimes v1 v2 of
        Nothing -> fail $ "Can't * " <> show v1 <> " and " <> show v2
        Just v -> pure v
    Divided e1 e2 -> do
      v1 <- evalExpr e1
      v2 <- evalExpr e2
      case maybeDividedBy v1 v2 of
        Nothing -> fail $ "Can't / " <> show v1 <> " and " <> show v2
        Just v -> pure v
    Set e args -> do
      v <- evalExpr e
      as' <- toArguments args
      case v of
        VFunction (Just name) _ _ ->
          updateState $ \st ->
            st
              { evalStyles =
                  M.alter
                    ( \case
                        Nothing -> Just as'
                        Just as'' -> Just (as'' <> as')
                    )
                    name
                    $ evalStyles st
              }
        _ -> fail $ "Set expects an element name"
      pure VNone
    Show mbSelExpr e -> do
      renderVal <- inBlock FunctionScope $ evalExpr e
      case mbSelExpr of
        Nothing -> do
          rest <- mconcat <$> (many pContent <* eof)
          case renderVal of
            VFunction _ _ (Function f) ->
              VContent . valToContent
                <$> f Arguments {positional = [VContent rest], named = OM.empty}
            _ -> pure $ VContent $ valToContent renderVal
        Just selExpr -> do
          selector <- evalExpr selExpr >>= toSelector
          case renderVal of
            VFunction _ _ (Function f) ->
              updateState $ \st ->
                st
                  { evalShowRules =
                      ShowRule
                        selector
                        ( \c ->
                            valToContent
                              <$> f
                                Arguments
                                  { positional = [VContent (Seq.singleton c)],
                                    named = OM.empty
                                  }
                        )
                        : evalShowRules st
                  }
            _ -> updateState $ \st ->
              st
                { evalShowRules =
                    ShowRule
                      selector
                      ( \c ->
                          case e of
                            -- ignore show set for now TODO
                            Set _ _ -> pure $ Seq.singleton c
                            _ -> pure (valToContent renderVal)
                      )
                      : evalShowRules st
                }
          pure VNone
    Binding _ -> fail $ "Encountered binding out of proper context"
    Assign e1 e2 -> do
      val <- evalExpr e2
      case e1 of
        Binding (BasicBind (Just ident)) -> updateIdentifier ident val
        Binding (BasicBind Nothing) -> pure ()
        Binding (DestructuringBind parts) ->
          destructuringBind updateIdentifier parts val
        x -> updateExpression x val
      pure VNone
    If clauses -> do
      let go [] = pure VNone
          go ((cond, e) : rest) = do
            val <- evalExpr cond
            case val of
              VBoolean True -> evalExpr e
              VBoolean False -> go rest
              _ -> fail "If requires a boolean condition"
      go clauses
    While e1 e2 -> do
      let go result = do
            condval <- evalExpr e1
            case condval of
              VBoolean True -> do
                val <- evalExpr e2
                hadBreak <- (== FlowBreak) . evalFlowDirective <$> getState
                joinVals result val >>= if hadBreak then pure else go
              VBoolean False -> pure result
              _ -> fail "While loop requires a boolean condition"
      updateState $ \st -> st {evalFlowDirective = FlowNormal}
      go VNone
    For bind e1 e2 -> do
      let go [] result = pure result
          go (x : xs) result = do
            case bind of
              BasicBind (Just ident) -> addIdentifier ident x
              BasicBind Nothing -> pure ()
              DestructuringBind parts ->
                destructuringBind addIdentifier parts x
            val <- evalExpr e2
            hadBreak <- (== FlowBreak) . evalFlowDirective <$> getState
            joinVals result val >>= if hadBreak then pure else go xs
      source <- evalExpr e1
      items <- case source of
        VString t -> pure $ map (VString . T.singleton) (T.unpack t)
        VArray v -> pure $ V.toList v
        VDict m ->
          pure $
            map
              ( \(Identifier k, v) ->
                  VArray (V.fromList [VString k, v])
              )
              (OM.assocs m)
        _ -> fail $ "For expression requires an Array or Dictionary"
      updateState $ \st -> st {evalFlowDirective = FlowNormal}
      go items VNone
    Return mbe -> do
      -- these flow directives are examined in CodeBlock
      updateState (\st -> st {evalFlowDirective = FlowReturn (isJust mbe)})
      maybe (pure VNone) evalExpr mbe
    Continue -> do
      updateState (\st -> st {evalFlowDirective = FlowContinue})
      pure VNone
    Break -> do
      updateState (\st -> st {evalFlowDirective = FlowBreak})
      pure VNone
    Label t -> pure $ VLabel t
    Import e imports -> do
      argval <- evalExpr e
      (modid, modmap) <-
        case argval of
          VString t -> loadModule t
          VModule i m -> pure (i, m)
          VFunction (Just i) m _ -> pure (i, m)
          VFunction Nothing m _ -> pure ("anonymous", m)
          _ -> fail "Import requires a path or module or function"
      case imports of
        AllIdentifiers -> importModule modmap
        SomeIdentifiers idents -> do
          let addFromModule m ident =
                case M.lookup ident modmap of
                  Nothing -> fail $ show ident <> " not defined in module"
                  Just v -> pure $ M.insert ident v m
          foldM addFromModule mempty idents >>= importModule
        NoIdentifiers -> addIdentifier modid (VModule modid modmap)
      pure VNone
    Include e -> do
      argval <- evalExpr e
      case argval of
        VString t -> loadModule t >>= importModule . snd
        _ -> fail "Include requires a path"
      pure VNone

toFunction ::
  Monad m =>
  Maybe Identifier ->
  [Param] ->
  Expr ->
  MP m Val
toFunction mbname params e = do
  idents <- evalIdentifiers <$> getState
  let fn = VFunction Nothing mempty $ Function $ \arguments -> do
        -- set identifiers from params and arguments
        let showIdentifier (Identifier i) = T.unpack i
        let isSinkParam (SinkParam {}) = True
            isSinkParam _ = False
        let setParam as (DefaultParam ident e') = do
              val <- case OM.lookup ident (named as) of
                Nothing -> evalExpr e'
                Just v -> pure v
              addIdentifier ident val
              pure $ as {named = OM.delete ident (named as)}
            setParam as (NormalParam ident) = do
              case positional as of
                [] -> fail ("Expected parameter " <> showIdentifier ident)
                (x : xs) -> do
                  addIdentifier ident x
                  pure $ as {positional = xs}
            setParam _ (SinkParam {}) =
              fail "setParam encountered SinkParam"
            setParam as (DestructuringParam parts) =
              case positional as of
                [] -> fail ("Expected parameter " <> show parts)
                (x : xs) -> do
                  destructuringBind addIdentifier parts x
                  pure $ as {positional = xs}
            setParam as SkipParam = pure as
        inBlock FunctionScope $ do
          -- We create a closure around the identifiers defined
          -- where the function is defined:
          oldState <- getState
          updateState $ \st -> st {evalIdentifiers = idents}
          case mbname of
            Nothing -> pure ()
            Just name -> addIdentifier name fn
          case break isSinkParam params of
            (befores, SinkParam mbident : afters) -> do
              as' <- foldM setParam arguments befores
              as'' <-
                foldM
                  setParam
                  as' {positional = reverse $ positional as'}
                  (reverse afters)
              let as = as'' {positional = reverse $ positional as''}
              case mbident of
                Just ident -> addIdentifier ident (VArguments as)
                Nothing -> pure ()
            _ -> foldM_ setParam arguments params
          res <- evalExpr e
          setState oldState
          pure res
  pure fn

loadModule :: Monad m => Text -> MP m (Identifier, M.Map Identifier Val)
loadModule modname = do
  pos <- getPosition
  let fp = replaceFileName (sourceName pos) (T.unpack modname)
  let modid = Identifier (T.pack $ takeBaseName fp)
  txt <- loadFileText fp
  case parseTypst fp txt of
    Left err -> fail $ show err
    Right ms -> do
      loadBytes <- evalLoadBytes <$> getState
      res <-
        lift $
          runParserT
            ( inBlock BlockScope $ -- add new identifiers list
                many pContent *> eof *> getState
            )
            initialEvalState {evalLoadBytes = loadBytes}
            fp
            ms
      case res of
        Left err' -> fail $ show err'
        Right st ->
          case evalIdentifiers st of
            [] -> fail "Empty evalIdentifiers in module!"
            ((_, m) : _) -> pure (modid, m)

importModule :: Monad m => M.Map Identifier Val -> MP m ()
importModule m = updateState $ \st ->
  st
    { evalIdentifiers =
        case evalIdentifiers st of
          [] -> [(BlockScope, m)]
          ((s, i) : is) -> (s, m <> i) : is
    }

evalLiteral :: Literal -> Val
evalLiteral lit =
  case lit of
    String t -> VString t
    Boolean b -> VBoolean b
    Float x -> VFloat x
    Int i -> VInteger i
    Numeric x unit ->
      case unit of
        Fr -> VFraction x
        Percent -> VRatio (toRational x / 100)
        Deg -> VAngle x
        Rad -> VAngle (x * (180 / pi))
        Pt -> VLength (LExact x LPt)
        Em -> VLength (LExact x LEm)
        Mm -> VLength (LExact x LMm)
        Cm -> VLength (LExact x LCm)
        In -> VLength (LExact x LIn)
    None -> VNone
    Auto -> VAuto

toArguments :: Monad m => [Arg] -> MP m Arguments
toArguments = foldM addArg (Arguments mempty OM.empty)
  where
    addArg args (KeyValArg ident e) = do
      val <- evalExpr e
      pure $ args {named = named args OM.|> (ident, val)}
    addArg args (NormalArg e) = do
      val <- evalExpr e
      pure $ args {positional = positional args ++ [val]}
    addArg args (ArrayArg rows) = do
      let pRow =
            fmap (VArray . V.fromList)
              . mapM (fmap VContent . pInnerContents . (: []))
      vals <- mapM pRow rows
      pure $ args {positional = positional args ++ vals}
    addArg args (SpreadArg e) = do
      val <- evalExpr e
      case val of
        VNone -> pure mempty
        VArguments args' -> pure $ args <> args'
        VDict m ->
          pure $
            args
              <> Arguments {positional = mempty, named = m}
        VArray v ->
          pure $
            args
              <> Arguments {positional = V.toList v, named = OM.empty}
        _ -> fail $ "spread requires an argument value, got " <> show val
    addArg args (BlockArg ms) = do
      val <- pInnerContents ms
      pure $ args {positional = positional args ++ [VContent val]}

addIdentifier :: Monad m => Identifier -> Val -> MP m ()
addIdentifier ident val = do
  identifiers <- evalIdentifiers <$> getState
  case identifiers of
    [] -> fail "Empty evalIdentifiers"
    ((s, i) : is) -> updateState $ \st ->
      st
        { evalIdentifiers = (s, M.insert ident val i) : is
        }

updateIdentifier :: Monad m => Identifier -> Val -> MP m ()
updateIdentifier ident val = do
  let go (True, is) (s, m) = pure (True, (s, m) : is)
      go (False, is) (s, m) =
        case M.lookup ident m of
          Nothing
            | s == FunctionScope -> fail $ show ident <> " not defined in scope"
            | otherwise -> pure (False, (s, m) : is)
          Just _ -> pure (True, (s, M.adjust (const val) ident m) : is)
  (finished, newmaps) <- getState >>= foldM go (False, []) . evalIdentifiers
  if finished
    then updateState $ \st -> st {evalIdentifiers = reverse newmaps}
    else fail $ show ident <> " not defined"

inBlock :: Monad m => Scope -> MP m a -> MP m a
inBlock scope pa = do
  oldStyles <- evalStyles <$> getState
  -- add a new identifiers map
  updateState $ \st ->
    st
      { evalIdentifiers = (scope, mempty) : evalIdentifiers st
      }
  result <- pa
  updateState $ \st ->
    st
      { evalIdentifiers = drop 1 (evalIdentifiers st),
        evalStyles = oldStyles
      }
  pure result

updateExpression :: Monad m => Expr -> Val -> MP m ()
updateExpression e val =
  case e of
    Ident i -> updateIdentifier i val
    FuncCall
      (FieldAccess (Ident (Identifier "at")) e')
      [NormalArg (Literal (Int idx))] ->
        do
          ival <- evalExpr e'
          case ival of
            VArray v ->
              updateExpression e' $ VArray $ v V.// [(fromIntegral idx, val)]
            _ -> fail $ "Cannot update expression " <> show e
    FuncCall (FieldAccess (Ident (Identifier "first")) e') [] ->
      updateExpression
        ( FuncCall
            (FieldAccess (Ident (Identifier "at")) e')
            [NormalArg (Literal (Int 0))]
        )
        val
    FuncCall (FieldAccess (Ident (Identifier "last")) e') [] ->
      updateExpression
        ( FuncCall
            (FieldAccess (Ident (Identifier "at")) e')
            [NormalArg (Literal (Int (-1)))]
        )
        val
    FuncCall
      (FieldAccess (Ident (Identifier "at")) e')
      [NormalArg (Literal (String fld))] ->
        do
          ival <- evalExpr e'
          case ival of
            VDict d ->
              updateExpression e' $
                VDict $
                  OM.alter
                    ( \case
                        Just _ -> Just val
                        Nothing -> Just val
                    )
                    (Identifier fld)
                    d
            _ -> fail $ "Cannot update expression " <> show e
    FieldAccess (Ident (Identifier fld)) e' ->
      updateExpression
        ( FuncCall
            (FieldAccess (Ident (Identifier "at")) e')
            [NormalArg (Literal (String fld))]
        )
        val
    _ -> fail $ "Cannot update expression " <> show e

toSelector :: Monad m => Val -> MP m Selector
toSelector (VSelector s) = pure s
toSelector (VFunction (Just name) _ _) = pure $ SelectElement name []
toSelector (VString t) = pure $ SelectString t
toSelector (VRegex re) = pure $ SelectRegex re
toSelector (VLabel t) = pure $ SelectLabel t
toSelector (VSymbol (Symbol t _ _)) = pure $ SelectString t
toSelector v = fail $ "could not convert " <> show v <> " to selector"
