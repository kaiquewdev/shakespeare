{-# LANGUAGE RankNTypes #-}
module Text.Hamlet.Monad
    ( -- * Datatypes
      Hamlet (..)
    , HtmlContent (..)
      -- * Output
    , output
    , outputHtml
    , outputString
    , outputOctets
    , outputUrl
    , outputUrlParams
    , outputEmbed
      -- * Utility functions
    , htmlContentToByteString
    , mapH
    , condH
    , maybeH
    , printHamlet
    , hamletToByteString
    , cdata
    ) where

import Data.ByteString.Char8 (ByteString, pack)
import qualified Data.ByteString.Char8 as S
import qualified Data.ByteString.Lazy as L
import Control.Applicative
import Control.Monad
import Data.Monoid
import Data.List
import Data.ByteString.UTF8 (fromString)

-- | Something to be run for each val. Returns 'Left' when enumeration should
-- terminate immediately, 'Right' when it can receive more input.
type Iteratee val seed m = seed -> val -> m (Either seed seed)

-- | Generates a stream of values to be passed to an 'Iteratee'.
newtype Enumerator val m = Enumerator
    { runEnumerator :: forall seed.
        Iteratee val seed m -> seed
     -> m (Either seed seed)
    }

-- | Convert a list into an 'Enumerator'.
fromList :: Monad m => [a] -> Enumerator a m
fromList x = Enumerator $ go x where
    go [] _ seed = return $ Right seed
    go (l:ls) iter seed = do
        ea <- iter seed l
        case ea of
            Left seed' -> return $ Left seed'
            Right seed' -> go ls iter seed'

-- | 'Hamlet' is a monad that has two features:
--
-- * It passes along a function to convert a URL to a 'String'.
--
-- * It keeps an 'Iteratee' and a seed value so that it can output values.
-- Output is all done through a strict 'Text' value.
--
-- The URL to String function makes it very convenient to write templates
-- without knowing the absolute URLs for all referenced resources. For more
-- information on this approach, please see the web-routes package.
--
-- For efficiency, the 'Hamlet' monad halts execution as soon as the underlying
-- 'Iteratee' returns a 'Left' value. This is normally what you want; this
-- might cause a problem if you are relying on the side effects of a 'Hamlet'
-- action. However, it is not recommended to rely on side-effects. Though a
-- 'Hamlet' monad may perform IO actions, this should only be used for
-- read-only behavior for efficiency.
newtype Hamlet url = Hamlet
    { runHamlet :: (url -> String) -> [ByteString] -> [ByteString]
    }
instance Monoid (Hamlet url) where
    mempty = Hamlet $ const id
    mappend (Hamlet x) (Hamlet y) = Hamlet $ \r -> x r . y r

-- | Directly output strict 'ByteString' without any escaping.
output :: ByteString -> Hamlet url
output = Hamlet . const . (:)

-- | Content for an HTML document. 'Encoded' content should not be entity
-- escaped; 'Unencoded' should be. All content must be UTF-8 encoded.
data HtmlContent = Encoded ByteString | Unencoded ByteString
    deriving (Eq, Show, Read)
instance Monoid HtmlContent where
    mempty = Encoded mempty
    mappend x y = Encoded $ mappend (htmlContentToByteString x)
                                    (htmlContentToByteString y)

-- | Wrap some 'HtmlContent' for embedding in an XML file.
cdata :: HtmlContent -> HtmlContent
cdata h = mconcat
    [ Encoded $ pack "<![CDATA["
    , h
    , Encoded $ pack "]]>"
    ]

-- | Outputs the given 'HtmlContent', entity encoding any 'Unencoded' data.
outputHtml :: HtmlContent -> Hamlet url
outputHtml = output . htmlContentToByteString

-- | 'pack' a 'String' and call 'output'; this will not perform any escaping. The String must be UTF8-octets.
outputString :: String -> Hamlet url
outputString = output . fromString

outputOctets :: String -> Hamlet url
outputOctets = output . pack

-- | Uses the URL rendering function to convert the given URL to a 'String' and
-- then calls 'outputString'.
outputUrl :: url -> Hamlet url
outputUrl u = Hamlet $ \render -> (:) (fromString $ render u)

-- | Same as 'outputUrl', but appends a query-string with given keys and
-- values.
outputUrlParams :: (url, [(String, String)]) -> Hamlet url
outputUrlParams (u, []) = outputUrl u
outputUrlParams (u, params) = mappend
    (outputUrl u)
    (outputString $ showParams params)
  where
    showParams x = '?' : intercalate "&" (map go x)
    go (x, y) = go' x ++ '=' : go' y
    go' = concatMap encodeUrlChar

-- | Taken straight from web-encodings; reimplemented here to avoid extra
-- dependencies.
encodeUrlChar :: Char -> String
encodeUrlChar c
    -- List of unreserved characters per RFC 3986
    -- Gleaned from http://en.wikipedia.org/wiki/Percent-encoding
    | 'A' <= c && c <= 'Z' = [c]
    | 'a' <= c && c <= 'z' = [c]
    | '0' <= c && c <= '9' = [c]
encodeUrlChar c@'-' = [c]
encodeUrlChar c@'_' = [c]
encodeUrlChar c@'.' = [c]
encodeUrlChar c@'~' = [c]
encodeUrlChar ' ' = "+"
encodeUrlChar y =
    let (a, c) = fromEnum y `divMod` 16
        b = a `mod` 16
        showHex' x -- FIXME just use Numeric version?
            | x < 10 = toEnum $ x + (fromEnum '0')
            | x < 16 = toEnum $ x - 10 + (fromEnum 'A')
            | otherwise = error $ "Invalid argument to showHex: " ++ show x
     in ['%', showHex' b, showHex' c]

-- | Only really used to ensure that the argument has the right type.
outputEmbed :: Hamlet url -> Hamlet url
outputEmbed = id

-- | Perform the given 'Hamlet' action for all values generated by the given
-- 'Enumerator'.
mapH :: (val -> Hamlet url)
     -> [val]
     -> Hamlet url
mapH each vals = mconcat $ map each vals

-- | Checks for truth in the left value in each pair in the first argument. If
-- a true exists, then the corresponding right action is performed. Only the
-- first is performed. In there are no true values, then the second argument is
-- performed, if supplied.
condH :: [(Bool, Hamlet url)] -- FIXME could probably just be a foldr
      -> Maybe (Hamlet url)
      -> Hamlet url
condH [] Nothing = mempty
condH [] (Just x) = x
condH ((True, y):_) _ = y
condH ((False, _):rest) z = condH rest z

-- | Runs the second argument with the value in the first, if available.
-- Otherwise, runs the third argument, if available.
maybeH :: Maybe v
       -> (v -> Hamlet url)
       -> Maybe (Hamlet url)
       -> Hamlet url
maybeH Nothing _ Nothing = mempty
maybeH Nothing _ (Just x) = x
maybeH (Just v) f _ = f v

-- | Prints a Hamlet to standard out. Good for debugging.
printHamlet :: (url -> String) -> Hamlet url -> IO ()
printHamlet render h = L.putStr $ hamletToByteString render h

-- | Converts a 'Hamlet' to lazy text, using strict I/O.
hamletToByteString :: (url -> String) -> Hamlet url -> L.ByteString
hamletToByteString render h = L.fromChunks $ runHamlet h render []

-- | Returns HTML-ready text (ie, all entities are escaped properly).
htmlContentToByteString :: HtmlContent -> ByteString
htmlContentToByteString (Encoded t) = t
htmlContentToByteString (Unencoded t) = S.concatMap (pack . encodeHtmlChar) t

encodeHtmlChar :: Char -> String
encodeHtmlChar '<' = "&lt;"
encodeHtmlChar '>' = "&gt;"
encodeHtmlChar '&' = "&amp;"
encodeHtmlChar '"' = "&quot;"
encodeHtmlChar '\'' = "&#39;"
encodeHtmlChar c = [c]
