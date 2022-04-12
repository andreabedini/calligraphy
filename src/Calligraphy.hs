{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Calligraphy (main, mainWithConfig) where

import qualified Calligraphy.Compat.GHC as GHC
import Calligraphy.Phases.Collapse
import Calligraphy.Phases.DependencyFilter
import Calligraphy.Phases.EdgeFilter
import Calligraphy.Phases.NodeFilter
import Calligraphy.Phases.Parse
import Calligraphy.Phases.Render
import Calligraphy.Phases.Search
import Calligraphy.Util.Debug
import Calligraphy.Util.Printer
import Control.Monad.RWS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as Text
import Data.Version (showVersion)
import Options.Applicative
import Paths_calligraphy (version)
import System.Directory (findExecutable)
import System.Exit
import System.IO (stderr)
import System.Process

main :: IO ()
main = do
  config <- execParser $ info (pConfig <**> helper <**> versionP) mempty
  mainWithConfig config
  where
    versionP =
      infoOption
        ( "calligraphy version "
            <> showVersion version
            <> "\nhie version "
            <> show GHC.hieVersion
        )
        (long "version" <> help "Show version")

mainWithConfig :: AppConfig -> IO ()
mainWithConfig AppConfig {..} = do
  let debug :: (DebugConfig -> Bool) -> Printer () -> IO ()
      debug fp printer = when (fp debugConfig) (printStderr printer)

  hieFiles <- searchFiles searchConfig
  when (null hieFiles) $ die "No files matched your search criteria.."
  debug dumpHieFile $ mapM_ ppHieFile hieFiles

  (modulesDebug, modules) <- either (printDie . ppParseError) pure (parseHieFiles hieFiles)
  debug dumpLexicalTree $ ppModulesDebugInfo modulesDebug
  debug dumpParsedModules $ ppModules modules

  let modulesCollapsed = collapse collapseConfig modules
  debug dumpCollapsedModules $ ppModules modulesCollapsed

  modulesFiltered <- either (printDie . ppFilterError) pure $ dependencyFilter dependencyFilterConfig modulesCollapsed
  let modulesEdgeFiltered = filterEdges edgeFilterConfig modulesFiltered
  let modulesNodeFiltered = filterNodes nodeFilterConfig modulesEdgeFiltered
  debug dumpFilteredModules $ ppModules modulesNodeFiltered

  let txt = runPrinter $ render renderConfig modulesNodeFiltered

  output outputConfig txt

data AppConfig = AppConfig
  { searchConfig :: SearchConfig,
    collapseConfig :: CollapseConfig,
    dependencyFilterConfig :: DependencyFilterConfig,
    edgeFilterConfig :: EdgeFilterConfig,
    nodeFilterConfig :: NodeFilterConfig,
    renderConfig :: RenderConfig,
    outputConfig :: OutputConfig,
    debugConfig :: DebugConfig
  }

printStderr :: Printer () -> IO ()
printStderr = Text.hPutStrLn stderr . runPrinter

printDie :: Printer () -> IO a
printDie txt = printStderr txt >> exitFailure

pConfig :: Parser AppConfig
pConfig =
  AppConfig <$> pSearchConfig
    <*> pCollapseConfig
    <*> pDependencyFilterConfig
    <*> pEdgeFilterConfig
    <*> pNodeFilterConfig
    <*> pRenderConfig
    <*> pOutputConfig
    <*> pDebugConfig

output :: OutputConfig -> Text -> IO ()
output cfg@OutputConfig {outputDotPath, outputPngPath, outputStdout} txt = do
  unless (hasOutput cfg) $ Text.hPutStrLn stderr "Warning: no output options specified, run with --help to see options"
  forM_ outputDotPath $ \fp -> Text.writeFile fp txt
  forM_ outputPngPath writePng
  when outputStdout $ Text.putStrLn txt
  where
    hasOutput (OutputConfig Nothing Nothing False) = False
    hasOutput _ = True

    writePng fp = do
      mexe <- findExecutable "dot"
      case mexe of
        Nothing -> die "no dot" -- TODO proper error here
        Just exe -> do
          (code, out, err) <- readProcessWithExitCode exe ["-Tpng", "-o", fp] (T.unpack txt)
          unless (code == ExitSuccess) $ do
            putStrLn "dot crashed"
            putStrLn out
            putStrLn err

data OutputConfig = OutputConfig
  { outputDotPath :: Maybe FilePath,
    outputPngPath :: Maybe FilePath,
    outputStdout :: Bool
  }

pOutputConfig :: Parser OutputConfig
pOutputConfig =
  OutputConfig
    <$> optional (strOption (short 'd' <> long "output-dot" <> metavar "FILE" <> help ".dot output path"))
    <*> optional (strOption (short 'p' <> long "output-png" <> metavar "FILE" <> help ".png output path (requires 'dot' executable in PATH)"))
    <*> switch (long "output-stdout" <> help "Output to stdout")

data DebugConfig = DebugConfig
  { dumpHieFile :: Bool,
    dumpLexicalTree :: Bool,
    dumpParsedModules :: Bool,
    dumpCollapsedModules :: Bool,
    dumpFilteredModules :: Bool
  }

-- TODO Move to Debug?
pDebugConfig :: Parser DebugConfig
pDebugConfig =
  DebugConfig
    <$> switch (long "ddump-hie-file" <> help "Debug dump raw HIE files.")
    <*> switch (long "ddump-lexical-tree" <> help "Debug dump the reconstructed lexical structure of HIE files, the intermediate output in the parsing phase.")
    <*> switch (long "ddump-parsed" <> help "Debug dump the final parsing phase output, i.e. reconstructed and cleaned up AST.")
    <*> switch (long "ddump-collapsed" <> help "Debug dump ASTs after the collapsing phase.")
    <*> switch (long "ddump-filtered" <> help "Debug dump ASTs after the filtering phase.")
