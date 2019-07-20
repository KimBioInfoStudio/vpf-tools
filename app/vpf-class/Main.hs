{-# language OverloadedStrings #-}
{-# language MonoLocalBinds #-}
module Main where

import Control.Applicative ((<**>))
import Control.Eff (Eff, Member, Lifted, LiftedBase, lift, runLift)
import Control.Eff.Reader.Strict (runReader)
import Control.Eff.Exception (Exc, runError, Fail, die, ignoreFail)
import Control.Lens (Lens, view, over, mapped, (&))

import qualified Data.Array                 as Array
import qualified Data.ByteString            as BS
import Data.Foldable (toList)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text.Encoding         as T
import qualified Text.Regex.Base            as PCRE
import qualified Text.Regex.PCRE.ByteString as PCRE

import qualified Options.Applicative as OptP

import Frames (FrameRec, Record)

import VPF.Eff.Cmd (Cmd, runCmd)
import VPF.Ext.HMMER.Search (HMMSearch, HMMSearchError, hmmsearchConfig, execHMMSearch)
import VPF.Ext.Prodigal (Prodigal, ProdigalError, prodigalConfig, execProdigal)

import VPF.Formats
import qualified VPF.Model.Class      as Cls
import qualified VPF.Model.Class.Cols as Cls
import qualified VPF.Model.Cols       as M
import qualified VPF.Model.VirusClass as VC

import qualified VPF.Util.Dplyr as D
import qualified VPF.Util.DSV   as DSV
import qualified VPF.Util.Fasta as FA
import qualified VPF.Util.FS    as FS
import VPF.Util.Vinyl (rsubset')

import Pipes ((>->))
import qualified Pipes.Core    as P
import qualified Pipes.Prelude as P
import qualified Pipes.Safe    as P

import qualified System.Directory as D

import qualified Opts


type OutputCols = VC.PredictedCols '[M.VirusName, M.ModelName, M.NumHits]
type RawOutputCols = VC.RawPredictedCols '[M.VirusName, M.ModelName, M.NumHits]

type Config = Opts.Config (DSV "\t" OutputCols)


main :: IO ()
main = do
    parser <- Opts.configParserIO

    OptP.execParser (opts parser) >>= classify
  where
    opts parser = OptP.info (parser <**> OptP.helper) $
        OptP.fullDesc
        <> OptP.progDesc "Classify virus sequences using an existing VPF classification"
        <> OptP.header "vpf-class: VPF-based virus sequence classifier"


compileRegex :: (Lifted IO r, Member Fail r) => Text -> Eff r (Text -> Maybe Text)
compileRegex src = do
    erx <- lift $ PCRE.compile (PCRE.compUTF8 + PCRE.compAnchored)
                               (PCRE.execAnchored + PCRE.execNoUTF8Check)
                               (T.encodeUtf8 src)
    case erx of
      Left (_, err) -> do
          lift $ putStrLn $ "Could not compile the regex " ++ show src ++ ": " ++ err
          die

      Right rx -> return $ \text -> do
          let btext = T.encodeUtf8 text
          arr <- PCRE.matchOnce rx btext
          (off, len) <- listToMaybe (toList arr)

          return (T.decodeUtf8 (BS.drop off (BS.take len btext)))


classify :: Config -> IO ()
classify cfg =
    runLift $ ignoreFail $ handleDSVParseErrors $ do
        virusNameExtractor <- compileRegex (Opts.virusNameRegex cfg)

        let modelCfg = VC.ModelConfig
              { VC.modelEValueThreshold    = Opts.evalueThreshold cfg
              , VC.modelVirusNameExtractor = \protName ->
                  fromMaybe (error $ "Could not extract virus name from protein: " ++ show protName)
                            (virusNameExtractor protName)
              }

        hitCounts <- runReader modelCfg $
            case Opts.inputFiles cfg of
              Opts.GivenHitsFile hitsFile ->
                  VC.runModel (VC.GivenHitsFile hitsFile)

              Opts.GivenSequences vpfsFile genomesFile ->
                  withCfgWorkDir cfg $ \workDir ->
                  withProdigalCfg cfg $
                  withHMMSearchCfg cfg $
                  handleFastaParseErrors $ do
                    let concOpts = Opts.concurrencyOpts cfg
                    VC.runModel (VC.GivenGenomes workDir vpfsFile genomesFile concOpts)

        cls <- Cls.loadClassification (Opts.vpfClassFile cfg)

        let predictedCls = VC.predictClassification hitCounts cls

            rawPredictedCls = over (mapped.rsubset') (view Cls.rawClassification)
                                   predictedCls
                            & D.reorder @RawOutputCols

            tsvOpts = DSV.defWriterOptions '\t'

        lift $
          case Opts.outputFile cfg of
            Opts.StdDevice ->
                DSV.writeDSV tsvOpts FS.stdoutWriter rawPredictedCls
            Opts.FSPath fp ->
                P.runSafeT $
                  DSV.writeDSV tsvOpts (FS.fileWriter (untag fp)) rawPredictedCls


withCfgWorkDir :: LiftedBase IO r
               => Config
               -> (Path Directory -> Eff r a)
               -> Eff r a
withCfgWorkDir cfg fm =
    case Opts.workDir cfg of
      Nothing ->
          FS.withTmpDir "." "vpf-work" fm

      Just wd -> do
          lift $ D.createDirectoryIfMissing True (untag wd)
          fm wd


withProdigalCfg :: (Lifted IO r, Member Fail r)
               => Config
               -> Eff (Cmd Prodigal ': Exc ProdigalError ': r) a
               -> Eff r a
withProdigalCfg cfg m = do
    handleProdigalErrors $ do
      prodigalCfg <- prodigalConfig (Opts.prodigalPath cfg) []
      execProdigal prodigalCfg m
  where
    handleProdigalErrors :: (Lifted IO r, Member Fail r)
                         => Eff (Exc ProdigalError ': r) a -> Eff r a
    handleProdigalErrors m = do
        res <- runError m

        case res of
          Right a -> return a
          Left e -> do
            lift $ putStrLn $ "prodigal error: " ++ show e
            die


withHMMSearchCfg :: (Lifted IO r, Member Fail r)
                 => Config
                 -> Eff (Cmd HMMSearch ': Exc HMMSearchError ': r) a
                 -> Eff r a
withHMMSearchCfg cfg m = do
    handleHMMSearchErrors $ do
      hmmsearchCfg <- hmmsearchConfig (Opts.hmmerConfig cfg) []
      execHMMSearch hmmsearchCfg m
  where
    handleHMMSearchErrors :: (Lifted IO r, Member Fail r)
                          => Eff (Exc HMMSearchError ': r) a -> Eff r a
    handleHMMSearchErrors m = do
        res <- runError m

        case res of
          Right a -> return a
          Left e -> do
            lift $ putStrLn $ "hmmsearch error: " ++ show e
            die


handleFastaParseErrors :: (Lifted IO r, Member Fail r)
                       => Eff (Exc FA.ParseError ': r) a
                       -> Eff r a
handleFastaParseErrors m = do
    res <- runError m

    case res of
      Right a -> return a

      Left (FA.ExpectedNameLine found) -> do
        lift $ putStrLn $
          "FASTA parsing error: expected name line but found " ++ show found
        die

      Left (FA.ExpectedSequenceLine []) -> do
        lift $ putStrLn $
          "FASTA parsing error: expected sequence but found EOF"
        die

      Left (FA.ExpectedSequenceLine (l:_)) -> do
        lift $ putStrLn $
          "FASTA parsing error: expected sequence but found " ++ show l
        die


handleDSVParseErrors :: (Lifted IO r, Member Fail r)
                     => Eff (Exc DSV.ParseError ': r) a
                     -> Eff r a
handleDSVParseErrors m = do
    res <- runError m

    case res of
      Right a -> return a
      Left (DSV.ParseError ctx row) -> do
        lift $ do
          putStrLn $ "could not parse row " ++ show row
          putStrLn $ " within " ++ show ctx
        die
