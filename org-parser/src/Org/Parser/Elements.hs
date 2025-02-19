module Org.Parser.Elements where

import Data.Text qualified as T
import Org.Builder qualified as B
import Org.Parser.Common
import Org.Parser.Definitions
import Org.Parser.MarkupContexts
import Org.Parser.Objects
import Relude.Extra hiding (elems, next)
import Text.Slugify (slugify)
import Prelude hiding (many, some)

-- | Read the start of a header line, return the header level
headingStart :: OrgParser Int
headingStart =
  try $
    (T.length <$> takeWhile1P (Just "heading bullets") (== '*'))
      <* char ' '
      <* skipSpaces

commentLine :: OrgParser (F OrgElements)
commentLine = try do
  hspace
  _ <- char '#'
  _ <-
    blankline' $> ""
      <|> char ' ' *> anyLine'
  pure mempty

elements :: OrgParser (F OrgElements)
elements = elements' (void (lookAhead headingStart) <|> eof)

elements' :: OrgParser end -> OrgParser (F OrgElements)
elements' end = mconcat <$> manyTill (element <|> para) end

-- | Each element parser must consume till the start of a line or EOF.
-- This is necessary for correct counting of list indentations.
element :: OrgParser (F OrgElements)
element =
  elementNonEmpty
    <|> blankline' $> mempty
    <* clearPendingAffiliated
      <?> "org element or blank line"

elementNonEmpty :: OrgParser (F OrgElements)
elementNonEmpty =
  elementIndentable
    <|> footnoteDef
      <* clearPendingAffiliated

elementIndentable :: OrgParser (F OrgElements)
elementIndentable =
  affKeyword
    <|> choice
      [ commentLine,
        exampleBlock,
        srcBlock,
        exportBlock,
        greaterBlock,
        plainList,
        latexEnvironment,
        drawer,
        keyword,
        horizontalRule,
        table
      ]
      <* clearPendingAffiliated
      <?> "org element"

para :: OrgParser (F OrgElements)
para = try do
  hspace
  f <- withAffiliated B.para
  (inls, next, _) <-
    withMContext__
      (/= '\n')
      end
      (plainMarkupContext standardSet)
  pure $ (f <*> inls) <> next
  where
    end :: OrgParser (F OrgElements)
    end = try do
      _ <- newline'
      lookAhead headingStart $> mempty
        <|> eof $> mempty
        <|> lookAhead blankline $> mempty
        <|> elementNonEmpty

-- * Plain lists

plainList :: OrgParser (F OrgElements)
plainList = try do
  f <- withAffiliated B.list
  ((indent, fstItem), i0) <- runStateT listItem 0
  rest <- evalStateT (many . try $ guardIndent indent =<< listItem) i0
  let kind = listItemType <$> fstItem
      items = (:) <$> fstItem <*> sequence rest
  pure $ f <*> kind <*> items
  where
    guardIndent indent (i, l) = guard (indent == i) $> l

listItem :: StateT Int OrgParser (Int, F ListItem)
listItem = try do
  (indent, bullet) <- lift $ unorderedBullet <|> counterBullet
  hspace1 <|> lookAhead (void newline')
  cookie <- lift $ optional counterSet
  box <- lift $ optional checkbox
  case cookie of
    Just n0 -> put n0
    Nothing -> modify (+ 1)
  n <- B.plain . show <$> get
  lift $ withTargetDescription (pure n) do
    tag <- case bullet of
      Bullet _ -> toList <<$>> option mempty itemTag
      _ -> pureF []
    els <-
      liftA2
        (<>)
        (blankline' $> mempty <|> indentedPara indent)
        (indentedElements indent)
    pure (indent, ListItem bullet cookie box <$> tag <*> (toList <$> els))
  where
    unorderedBullet =
      fmap (second Bullet) $
        try ((,) <$> spacesOrTabs <*> satisfy \c -> c == '+' || c == '-')
          <|> try ((,) <$> spacesOrTabs1 <*> char '*')
    counterBullet = try do
      indent <- spacesOrTabs
      counter <- digits1 <|> T.singleton <$> satisfy isAsciiAlpha
      d <- satisfy \c -> c == '.' || c == ')'
      pure (indent, Counter counter d)

counterSet :: OrgParser Int
counterSet =
  try $
    string "[@"
      *> parseNum
      <* char ']'
      <* hspace
  where
    parseNum = integer <|> asciiAlpha'

checkbox :: OrgParser Checkbox
checkbox =
  try $
    char '['
      *> tick
      <* char ']'
      <* (hspace1 <|> lookAhead (void newline'))
  where
    tick =
      char ' ' $> BoolBox False
        <|> char 'X' $> BoolBox True
        <|> char '-' $> PartialBox

itemTag :: OrgParser (F OrgObjects)
itemTag = try do
  clearLastChar
  st <- getFullState
  (contents, found) <- findSkipping (not . isSpace) end
  guard found
  parseFromText st contents (plainMarkupContext standardSet)
  where
    end =
      spaceOrTab *> string "::" *> spaceOrTab $> True
        <|> newline' $> False

indentedPara :: Int -> OrgParser (F OrgElements)
indentedPara indent = try do
  hspace
  f <- withAffiliated B.para
  (inls, next, _) <-
    withMContext__
      (/= '\n')
      end
      (plainMarkupContext standardSet)
  pure $ (f <*> inls) <> next
  where
    end :: OrgParser (F OrgElements)
    end = try do
      _ <- newline'
      lookAhead blankline' $> mempty
        <|> lookAhead headingStart $> mempty
        -- We don't want to consume any indentation, so we look ahead.
        <|> lookAhead (try $ guard . (<= indent) =<< spacesOrTabs) $> mempty
        <|> element

indentedElements :: Int -> OrgParser (F OrgElements)
indentedElements indent =
  mconcat <$> many indentedElement
  where
    indentedElement = try do
      notFollowedBy headingStart
      blankline
        *> notFollowedBy blankline'
        *> clearPendingAffiliated $> mempty
        <|> do
          guard . (> indent) =<< lookAhead spacesOrTabs
          elementNonEmpty <|> indentedPara indent

-- * Lesser blocks

exampleBlock :: OrgParser (F OrgElements)
exampleBlock = try do
  hspace
  f <- withAffiliated B.example
  _ <- string'' "#+begin_example"
  switches <- blockSwitches
  _ <- anyLine
  startingNumber <- updateLineNumbers switches
  contents <- rawBlockContents end switches
  pure $ f ?? startingNumber ?? contents
  where
    end = try $ hspace *> string'' "#+end_example" <* blankline'

srcBlock :: OrgParser (F OrgElements)
srcBlock = try do
  hspace
  f <- withAffiliated B.srcBlock
  _ <- string'' "#+begin_src"
  lang <- option "" $ hspace1 *> someNonSpace
  switches <- blockSwitches
  args <- headerArgs
  num <- updateLineNumbers switches
  contents <- rawBlockContents end switches
  pure $ f ?? lang ?? num ?? args ?? contents
  where
    end = try $ hspace *> string'' "#+end_src" <* blankline'

headerArgs :: StateT OrgParserState Parser [(Text, Text)]
headerArgs = do
  hspace
  fromList <$> headerArg `sepBy` hspace1
    <* anyLine'
  where
    headerArg =
      liftA2
        (,)
        (char ':' *> someNonSpace)
        ( T.strip . fst
            <$> findSkipping
              (not . isSpace)
              ( try $
                  lookAhead
                    ( newline'
                        <|> hspace1 <* char ':'
                    )
              )
        )

exportBlock :: OrgParser (F OrgElements)
exportBlock = try do
  hspace
  _ <- string'' "#+begin_export"
  format <- option "" $ hspace1 *> someNonSpace
  _ <- anyLine
  contents <- T.unlines <$> manyTill anyLine end
  pureF $ B.export format contents
  where
    end = try $ hspace *> string'' "#+end_export" <* blankline'

-- verseBlock :: OrgParser (F OrgElements)
-- verseBlock = try do
--   hspace
--   _ <- string'' "#+begin_verse"
--   undefined
--   where
-- end = try $ hspace *> string'' "#+end_export" <* blankline'

indentContents :: Int -> [SrcLine] -> [SrcLine]
indentContents tabWidth (map (srcLineMap $ tabsToSpaces tabWidth) -> lins) =
  map (srcLineMap $ T.drop minIndent) lins
  where
    minIndent = maybe 0 minimum1 (nonEmpty $ map (indentSize . srcLineContent) lins)
    indentSize = T.length . T.takeWhile (== ' ')

tabsToSpaces :: Int -> Text -> Text
tabsToSpaces tabWidth txt =
  T.span (\c -> c == ' ' || c == '\t') txt
    & first
      ( flip T.replicate " "
          . uncurry (+)
          . bimap T.length ((* tabWidth) . T.length)
          . T.partition (== ' ')
      )
    & uncurry (<>)

updateLineNumbers :: Map Text Text -> OrgParser (Maybe Int)
updateLineNumbers switches =
  case "-n" `lookup` switches of
    Just (readMaybe . toString -> n) ->
      setSrcLineNum (fromMaybe 1 n)
        *> fmap Just getSrcLineNum
    _ -> case "+n" `lookup` switches of
      Just (readMaybe . toString -> n) ->
        incSrcLineNum (fromMaybe 0 n)
          *> fmap Just getSrcLineNum
      _ -> pure Nothing

rawBlockContents :: OrgParser void -> Map Text Text -> OrgParser [SrcLine]
rawBlockContents end switches = do
  contents <- manyTill (rawBlockLine switches) end
  tabWidth <- getsO orgTabWidth
  preserveIndent <- getsO orgSrcPreserveIndentation
  pure $
    if preserveIndent || "-i" `member` switches
      then map (srcLineMap (tabsToSpaces tabWidth)) contents
      else indentContents tabWidth contents

quotedLine :: OrgParser Text
quotedLine = do
  (<>) <$> option "" (try $ char ',' *> (string "*" <|> string "#+"))
    <*> anyLine

rawBlockLine :: Map Text Text -> OrgParser SrcLine
rawBlockLine switches =
  try $
    (applyRef =<< quotedLine)
      <* incSrcLineNum 1
  where
    (refpre, refpos) =
      maybe
        ("(ref:", ")")
        (second (T.drop 2) . T.breakOn "%s")
        $ lookup "-l" switches
    applyRef txt
      | Just (ref, content) <- flip parseMaybe (T.reverse txt) do
          (hspace :: Parsec Void Text ())
          _ <- string (T.reverse refpos)
          ref <-
            toText . reverse
              <$> someTill
                (satisfy $ \c -> isAsciiAlpha c || isDigit c || c == '-' || c == ' ')
                (string $ T.reverse refpre)
          content <- T.stripEnd . T.reverse <$> takeInput
          pure (ref, content) =
          do
            (ref', alias) <-
              if "-r" `member` switches
                then ("",) . show <$> getSrcLineNum
                else pure (ref, ref)
            let anchor = "coderef-" <> slugify ref
            registerAnchorTarget ("(" <> ref <> ")") anchor (pure $ B.plain alias)
            pure $ RefLine anchor ref' content
      | otherwise = pure $ SrcLine txt

blockSwitches :: OrgParser (Map Text Text)
blockSwitches = fromList <$> many (linum <|> switch <|> fmt)
  where
    linum :: OrgParser (Text, Text)
    linum = try $ do
      hspace1
      s <-
        T.snoc . one <$> oneOf ['+', '-']
          <*> char 'n'
      num <- option "" $ try $ hspace1 *> takeWhileP Nothing isDigit
      _ <- lookAhead spaceChar
      return (s, num)

    fmt :: OrgParser (Text, Text)
    fmt = try $ do
      hspace1
      s <- string "-l"
      hspace1
      str <-
        between (char '"') (char '"') $
          takeWhileP Nothing (\c -> c /= '"' && c /= '\n')
      _ <- lookAhead spaceChar
      return (s, str)

    switch :: OrgParser (Text, Text)
    switch = try $ do
      hspace1
      s <-
        T.snoc . one <$> char '-'
          <*> oneOf ['i', 'k', 'r']
      _ <- lookAhead spaceChar
      pure (s, "")

-- * Greater Blocks

greaterBlock :: OrgParser (F OrgElements)
greaterBlock = try do
  f <- withAffiliated B.greaterBlock
  hspace
  _ <- string'' "#+begin_"
  bname <- someNonSpace <* anyLine
  els <- withContext anyLine (end bname) elements
  clearPendingAffiliated
  pure $ f ?? blockType bname <*> els
  where
    blockType = \case
      (T.toLower -> "center") -> Center
      (T.toLower -> "quote") -> Quote
      other -> Special other
    end :: Text -> OrgParser Text
    end name = try $ hspace *> string'' "#+end_" *> string'' name <* blankline'

-- * Drawers

drawer :: OrgParser (F OrgElements)
drawer = try do
  hspace
  _ <- char ':'
  dname <- takeWhile1P (Just "drawer name") (\c -> c /= ':' && c /= '\n')
  char ':' >> blankline
  els <- withContext blankline end elements
  return $ B.drawer dname <$> els
  where
    end :: OrgParser ()
    end = try $ newline *> hspace <* string'' ":end:"

-- * LaTeX Environments

latexEnvironment :: OrgParser (F OrgElements)
latexEnvironment = try do
  hspace
  _ <- string "\\begin{"
  ename <-
    takeWhile1P
      (Just "latex environment name")
      (\c -> isAsciiAlpha c || isDigit c || c == '*')
  _ <- char '}'
  (str, _) <- findSkipping (/= '\\') (end ename)
  f <- withAffiliated B.latexEnvironment
  pure $ f ?? ename ?? "\\begin{" <> ename <> "}" <> str <> "\\end{" <> ename <> "}"
  where
    end :: Text -> OrgParser ()
    end name = try $ string ("\\end{" <> name <> "}") *> blankline'

-- * Keywords and affiliated keywords

affKeyword :: OrgParser (F OrgElements)
affKeyword = try do
  hspace
  _ <- string "#+"
  try do
    (T.toLower -> name) <-
      liftA2
        (<>)
        (string'' "attr_")
        (takeWhile1P Nothing (\c -> not (isSpace c || c == ':')))
    _ <- char ':'
    args <- headerArgs
    registerAffiliated $ pure (name, B.attrKeyword args)
    pure mempty
    <|> try do
      affkws <- getsO orgElementAffiliatedKeywords
      name <- choice (fmap (\s -> string'' s $> s) affkws)
      isdualkw <- (name `elem`) <$> getsO orgElementDualKeywords
      isparsedkw <- (name `elem`) <$> getsO orgElementParsedKeywords
      value <-
        if isparsedkw
          then do
            optArg <- option (pure mempty) $ guard isdualkw *> optionalArgP
            _ <- char ':'
            hspace
            st <- getFullState
            line <- anyLine'
            value <- parseFromText st line (plainMarkupContext standardSet)
            pure $ B.parsedKeyword <$> optArg <*> value
          else do
            optArg <- option "" $ guard isdualkw *> optionalArg
            _ <- char ':'
            hspace
            pure . B.valueKeyword optArg . T.stripEnd <$> anyLine'
      registerAffiliated $ (name,) <$> value
      pure mempty
  where
    optionalArgP =
      withBalancedContext '[' ']' (\c -> c /= '\n' && c /= ':') $
        plainMarkupContext standardSet
    optionalArg =
      withBalancedContext
        '['
        ']'
        (\c -> c /= '\n' && c /= ':')
        takeInput

keyword :: OrgParser (F OrgElements)
keyword = try do
  hspace
  _ <- string "#+"
  -- This is one of the places where it is convoluted to replicate org-element
  -- regexes: "#+abc:d:e :f" is a valid keyword of key "abc:d" and value "e :f".
  name <-
    T.toLower . fst <$> fix \me -> do
      res@(name, ended) <-
        findSkipping (\c -> c /= ':' && not (isSpace c)) $
          try $
            (newline' <|> void (satisfy isSpace)) $> False
              <|> char ':' *> notFollowedBy me $> True
      guard (not $ T.null name)
      guard ended <?> "keyword end"
      pure res
  hspace
  parsedkw <- (name `elem`) <$> getsO orgElementParsedKeywords
  value <-
    if parsedkw
      then
        B.parsedKeyword' <<$>> do
          st <- getFullState
          line <- anyLine'
          parseFromText st line (plainMarkupContext standardSet)
      else pure . B.valueKeyword' . T.stripEnd <$> anyLine'
  let kw = (name,) <$> value
  registerKeyword kw
  return $ uncurry B.keyword <$> kw

-- * Footnote definitions

footnoteDef :: OrgParser (F OrgElements)
footnoteDef = try do
  lbl <- start
  _ <- optional blankline'
  def <-
    elements' $
      lookAhead $
        void headingStart
          <|> try (blankline' *> blankline')
          <|> void (try start)
  registerFootnote lbl def
  pureF mempty
  where
    start =
      string "[fn:"
        *> takeWhile1P
          (Just "footnote def label")
          (\c -> isAlphaNum c || c == '-' || c == '_')
        <* char ']'

-- * Horizontal Rules

horizontalRule :: OrgParser (F OrgElements)
horizontalRule = try do
  hspace
  l <- T.length <$> takeWhile1P (Just "hrule dashes") (== '-')
  guard (l >= 5)
  blankline'
  pureF B.horizontalRule

-- * Tables

table :: OrgParser (F OrgElements)
table = try do
  hspace
  f <- withAffiliated B.table
  _ <- lookAhead $ char '|'
  rows <- sequence <$> some tableRow
  pure (f <*> rows)
  where
    tableRow :: OrgParser (F TableRow)
    tableRow = ruleRow <|> columnPropRow <|> standardRow

    ruleRow = try $ pure RuleRow <$ (hspace >> string "|-" >> anyLine')

    columnPropRow = try do
      hspace
      _ <- char '|'
      pure . ColumnPropsRow <$> some cell
        <* blankline'
      where
        cell = do
          hspace
          c <- Just <$> cookie <|> Nothing <$ void (char '|')
          pure c
        cookie = try do
          a <-
            string "<l" $> AlignLeft
              <|> string "<c" $> AlignCenter
              <|> string "<r" $> AlignRight
          _ <- digits
          _ <- char '>'
          hspace
          void (char '|') <|> lookAhead newline'
          pure a

    standardRow = try do
      hspace
      _ <- char '|'
      B.standardRow <<$>> sequence <$> some cell
        <* blankline'
      where
        cell = do
          hspace
          char '|' $> mempty
            <|> withMContext
              (\c -> not $ isSpace c || c == '|')
              end
              (plainMarkupContext standardSet)
        end = try $ hspace >> void (char '|') <|> lookAhead newline'
