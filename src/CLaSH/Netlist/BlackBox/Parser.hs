-- | Parser definitions for BlackBox templates
module CLaSH.Netlist.BlackBox.Parser
  (runParse)
where

import           Data.ListLike.Text.TextLazy              ()
import           Data.Text.Lazy                           (Text, pack)
import           Text.ParserCombinators.UU
import           Text.ParserCombinators.UU.BasicInstances hiding (Parser)
import qualified Text.ParserCombinators.UU.Core           as PCC (parse)
import           Text.ParserCombinators.UU.Utils          hiding (pBrackets)

import           CLaSH.Netlist.BlackBox.Types

type Parser a = P (Str Char Text LineColPos) a


-- | Parse a text as a BlackBoxTemplate, returns a list of errors in case
-- parsing fails
runParse :: Text -> (BlackBoxTemplate, [Error LineColPos])
runParse = PCC.parse ((,) <$> pBlackBoxD <*> pEnd)
         . createStr (LineColPos 0 0 0)

-- | Parse a BlackBoxTemplate (Declarations and Expressions)
pBlackBoxD :: Parser BlackBoxTemplate
pBlackBoxD = pSome pElement

-- | Parse a single Template Element
pElement :: Parser Element
pElement  =  pTagD
         <|> C <$> pText

-- | Parse the Text part of a Template
pText :: Parser Text
pText = pack <$> pList1 (pRange ('\000','\125'))

-- | Parse a Declaration or Expression element
pTagD :: Parser Element
pTagD =  D <$> pDecl
     <|> pTagE

-- | Parse a Declaration
pDecl :: Parser Decl
pDecl = Decl <$> (pTokenWS "~INST" *> pNatural) <*>
        ((:) <$> pOutput <*> pList pInput) <* pToken "~INST"

-- | Parse the output tag of Declaration
pOutput :: Parser BlackBoxTemplate
pOutput = pTokenWS "~OUTPUT" *> pTokenWS "<=" *> pBlackBoxE <* pTokenWS "~"

-- | Parse the input tag of Declaration
pInput :: Parser BlackBoxTemplate
pInput = pTokenWS "~INPUT" *> pTokenWS "<=" *> pBlackBoxE <* pTokenWS "~"

-- | Parse an Expression element
pTagE :: Parser Element
pTagE =  O             <$  pToken "~RESULT"
     <|> I             <$> (pToken "~ARG" *> pBrackets pNatural)
     <|> I             <$> (pToken "~LIT" *> pBrackets pNatural)
     <|> (Clk . Just)  <$> (pToken "~CLK" *> pBrackets pNatural)
     <|> Clk Nothing   <$  pToken "~CLKO"
     <|> (Rst . Just)  <$> (pToken "~RST" *> pBrackets pNatural)
     <|> Rst Nothing   <$  pToken "~RSTO"
     <|> Sym           <$> (pToken "~SYM" *> pBrackets pNatural)
     <|> Typ Nothing   <$  pToken "~TYPO"
     <|> (Typ . Just)  <$> (pToken "~TYP" *> pBrackets pNatural)
     <|> TypM Nothing  <$  pToken "~TYPMO"
     <|> (TypM . Just) <$> (pToken "~TYPM" *> pBrackets pNatural)
     <|> Def Nothing   <$  pToken "~DEFAULTO"
     <|> (Def . Just)  <$> (pToken "~DEFAULT" *> pBrackets pNatural)

-- | Parse a bracketed text
pBrackets :: Parser a -> Parser a
pBrackets p = pSym '[' *> p <* pSym ']'

-- | Parse a token and eat trailing whitespace
pTokenWS :: String -> Parser String
pTokenWS keyw = pToken keyw <* pSpaces

-- | Parse the expression part of Blackbox Templates
pBlackBoxE :: Parser BlackBoxTemplate
pBlackBoxE = pSome pElemE

-- | Parse an Expression or Text
pElemE :: Parser Element
pElemE = pTagE
      <|> C <$> pText
