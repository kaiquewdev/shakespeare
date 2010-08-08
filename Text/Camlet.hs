{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
module Text.Camlet
    ( Camlet
    , renderCamlet
    , CamletMixin
    , camletMixin
    , camlet
    , Color (..)
    , colorRed
    , colorBlack
    ) where

import Text.ParserCombinators.Parsec hiding (Line)
import Data.Neither (AEither (..), either)
import Data.Traversable (sequenceA)
import Control.Applicative ((<$>))
import Data.List (intercalate)
import Data.Char (isUpper, isDigit)
import Language.Haskell.TH.Quote (QuasiQuoter (..))
import Language.Haskell.TH.Syntax
import Text.Blaze.Builder.Core (Builder, fromByteString, toLazyByteString)
import Text.Blaze.Builder.Utf8 (fromString)
import Data.Maybe (catMaybes)
import Prelude hiding (either)
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.UTF8 as BSU
import qualified Data.ByteString.Lazy as L
import Data.Monoid
import Data.Word (Word8)
import Data.Bits
import Text.Hamlet.Quasi (showParams)

data Color = Color Word8 Word8 Word8
    deriving Show
instance ToStyle Color where
    toStyle (Color r g b) =
        let (r1, r2) = toHex r
            (g1, g2) = toHex g
            (b1, b2) = toHex b
         in '#' :
            if r1 == r2 && g1 == g2 && b1 == b2
                then [r1, g1, b1]
                else [r1, r2, g1, g2, b1, b2]
      where
        toHex :: Word8 -> (Char, Char)
        toHex x = (toChar $ shiftR x 4, toChar $ x .&. 15)
        toChar :: Word8 -> Char
        toChar c
            | c < 10 = mkChar c 0 '0'
            | otherwise = mkChar c 10 'A'
        mkChar :: Word8 -> Word8 -> Char -> Char
        mkChar a b' c =
            toEnum $ fromIntegral $ a - b' + fromIntegral (fromEnum c)

colorRed :: Color
colorRed = Color 255 0 0

colorBlack :: Color
colorBlack = Color 0 0 0

renderStyle :: Style -> L.ByteString
renderStyle (Style b) = toLazyByteString b

renderCamlet :: (url -> String) -> Camlet url -> L.ByteString
renderCamlet r s = renderStyle $ s r

newtype Style = Style Builder
    deriving Monoid
type Camlet url = (url -> String) -> Style

class ToStyle a where
    toStyle :: a -> String
instance ToStyle [Char] where toStyle = id

data ContentPair = CPSimple Contents Contents
                 | CPMixin Deref
    deriving Show
contentPairToContents :: ContentPair -> Contents
contentPairToContents (CPSimple x y) = concat [x, ContentRaw ":" : y]
contentPairToContents (CPMixin deref) = [ContentMix deref]

data FlatDec = FlatDec Contents [ContentPair]
    deriving Show

data Deref = DerefLeaf String
           | DerefBranch Deref Deref
    deriving Show

data Content = ContentRaw String
             | ContentVar Deref
             | ContentUrl Deref
             | ContentUrlParam Deref
             | ContentMix Deref
    deriving Show
type Contents = [Content]

data DecS = Attrib Contents Contents
          | Block Contents [DecS]
          | MixinDec Deref
    deriving Show

data Line = LinePair Contents Contents
          | LineSingle Contents
          | LineMix Deref
    deriving Show

data Nest = Nest Line [Nest]
    deriving Show

parseLines :: Parser [(Int, Line)]
parseLines = fmap (catMaybes) $ many (parseEmptyLine <|> parseLine)

eol :: Parser ()
eol =
    (char '\n' >> return ()) <|> (string "\r\n" >> return ())

parseEmptyLine :: Parser (Maybe (Int, Line))
parseEmptyLine = eol >> return Nothing

parseLine :: Parser (Maybe (Int, Line))
parseLine = do
    ss <- fmap sum $ many ((char ' ' >> return 1) <|>
                           (char '\t' >> return 4))
    x <- parseLineMix <|> do
            key' <- many1 $ parseContent False
            let key = trim key'
            parsePair key <|> return (LineSingle key)
    eol <|> eof
    return $ Just (ss, x)
  where
    parseLineMix = do
        _ <- char '^'
        d <- parseDeref
        _ <- char '^'
        return $ LineMix d
    parsePair key = do
        _ <- char ':'
        _ <- spaces
        val <- many1 $ parseContent True
        return $ LinePair key $ trim val
    --trim = reverse . dropWhile isSpace . reverse
    trim = id -- FIXME

parseContent :: Bool -> Parser Content
parseContent allowColon = do
    (char '$' >> (parseDollar <|> parseVar)) <|>
      (char '@' >> (parseAt <|> parseUrl)) <|> do
        s <- many1 $ noneOf $ (if allowColon then id else (:) ':') "\r\n$@"
        return $ ContentRaw s
  where
    parseAt = char '@' >> return (ContentRaw "@")
    parseUrl = do
        c <- (char '?' >> return ContentUrlParam) <|> return ContentUrl
        d <- parseDeref
        _ <- char '@'
        return $ c d
    parseDollar = char '$' >> return (ContentRaw "$")
    parseVar = do
        d <- parseDeref
        _ <- char '$'
        return $ ContentVar d

parseDeref :: Parser Deref
parseDeref =
    deref
  where
    derefParens = between (char '(') (char ')') deref
    derefSingle = derefParens <|> fmap DerefLeaf ident
    deref = do
        let delim = (char '.' <|> (many1 (char ' ') >> return ' '))
        x <- derefSingle
        xs <- many $ delim >> derefSingle
        return $ foldr1 DerefBranch $ x : xs
    ident = many1 (alphaNum <|> char '_' <|> char '\'')

nestLines :: [(Int, Line)] -> [Nest]
nestLines [] = []
nestLines ((i, l):rest) =
    let (deeper, rest') = span (\(i', _) -> i' > i) rest
     in Nest l (nestLines deeper) : nestLines rest'

nestToDec :: Bool -> Nest -> AEither [String] DecS
nestToDec _ (Nest LineMix{} (_:_)) =
    ALeft ["Mixins may not have nested content"]
nestToDec True (Nest LineMix{} []) =
    ALeft ["Cannot have LineMix at top level"]
nestToDec False (Nest (LineMix deref) []) =
    ARight $ MixinDec deref
nestToDec _ (Nest LinePair{} (_:_)) =
    ALeft ["Only LineSingle may have nested content"]
nestToDec _ (Nest LineSingle{} []) =
    ALeft ["A LineSingle must have nested content"]
nestToDec True (Nest LinePair{} _) =
    ALeft ["Cannot have a LinePair at top level"]
nestToDec _ (Nest (LineSingle name) nests) =
    Block name <$> sequenceA (map (nestToDec False) nests)
nestToDec _ (Nest (LinePair key val) []) = ARight $ Attrib key val

flatDec :: DecS -> [FlatDec]
flatDec Attrib{} = error "flatDec Attrib"
flatDec MixinDec{} = error "flatDec MixinDec"
flatDec (Block name decs) =
    let as = concatMap getAttrib decs
        bs = concatMap getBlock decs
        a = case as of
                [] -> id
                _ -> (:) (FlatDec name as)
        b = concatMap flatDec bs
     in a b
  where
    getAttrib (Attrib x y) = [CPSimple x y]
    getAttrib (MixinDec d) = [CPMixin d]
    getAttrib Block{} = []
    getBlock (Block n d) = [Block (concat [name, ContentRaw " " : n]) d]
    getBlock _ = []

render :: FlatDec -> Contents
render (FlatDec n pairs) =
    let inner = intercalate [ContentRaw ";"]
              $ map contentPairToContents pairs
     in concat [n, [ContentRaw "{"], inner, [ContentRaw "}"]]

compressContents :: Contents -> Contents
compressContents [] = []
compressContents (ContentRaw x:ContentRaw y:z) =
    compressContents $ ContentRaw (x ++ y) : z
compressContents (x:y) = x : compressContents y

contentsToCamlet :: [Content] -> Q Exp
contentsToCamlet a = do
    r <- newName "_render"
    c <- mapM (contentToStyle r) $ compressContents a
    d <- case c of
            [] -> [|mempty|]
            [x] -> return x
            _ -> do
                mc <- [|mconcat|]
                return $ mc `AppE` ListE c
    return $ LamE [VarP r] d

camletMixin :: QuasiQuoter
camletMixin =
    QuasiQuoter e p
  where
    p = error "camletMixin quasi-quoter for patterns does not exist"
    e s = do
        let a = either (error . show) id
              $ parse parseLines s s
        let b = flip map a $ \(_, l) ->
                    case l of
                        LinePair x y -> CPSimple x y
                        LineMix deref -> CPMixin deref
                        LineSingle _ -> error "Mixins cannot contain singles"
        d <- contentsToCamlet
           $ intercalate [ContentRaw ";"]
           $ map contentPairToContents b
        sm <- [|CamletMixin|]
        return $ sm `AppE` d

newtype CamletMixin url = CamletMixin { unCamletMixin :: Camlet url }

camlet :: QuasiQuoter
camlet =
    QuasiQuoter e p
  where
    p = error "camlet quasi-quoter for patterns does not exist"
    e s = do
        let a = either (error . show) id
              $ parse parseLines s s
        let b = either (error . unlines) id
              $ sequenceA $ map (nestToDec True) $ nestLines a
        contentsToCamlet $ concatMap render $ concatMap flatDec b

contentToStyle :: Name -> Content -> Q Exp
contentToStyle _ (ContentRaw s') = do
    let d = S8.unpack $ BSU.fromString s'
    ts <- [|Style . fromByteString . S8.pack|]
    return $ ts `AppE` LitE (StringL d)
contentToStyle _ (ContentVar d) = do
    ts <- [|Style . fromString . toStyle|]
    return $ ts `AppE` derefToExp d
contentToStyle r (ContentUrl d) = do
    ts <- [|Style . fromString|]
    return $ ts `AppE` (VarE r `AppE` derefToExp d)
contentToStyle r (ContentUrlParam d) = do
    ts <- [|Style . fromString|]
    up <- [|\r' (u, p) -> r' u ++ showParams p|]
    return $ ts `AppE` (up `AppE` VarE r `AppE` derefToExp d)
contentToStyle r (ContentMix d) = do
    un <- [|unCamletMixin|]
    return $ un `AppE` derefToExp d `AppE` VarE r

derefToExp :: Deref -> Exp
derefToExp (DerefBranch x y) =
    let x' = derefToExp x
        y' = derefToExp y
     in x' `AppE` y'
derefToExp (DerefLeaf "") = error "Illegal empty ident"
derefToExp (DerefLeaf v@(s:_))
    | all isDigit v = LitE $ IntegerL $ read v
    | isUpper s = ConE $ mkName v
    | otherwise = VarE $ mkName v
