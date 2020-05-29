{- |
Copyright: (c) 2020 Kowainik
SPDX-License-Identifier: MPL-2.0
Maintainer: Kowainik <xrom.xkov@gmail.com>

Functions to work with cabal files and cabal extension maps.
-}

module Stan.Cabal
    ( createCabalExtensionsMap

    , mergeParsedExtensions
    ) where

import Relude.Extra.Tuple (mapToSnd)

import Colourista (errorMessage, infoMessage, warningMessage)
import Control.Exception (catch)
import Extensions (CabalException, ExtensionsError (..), ExtensionsResult, ParsedExtensions (..),
                   mergeAnyExtensions, parseCabalFileExtensions)
import HieTypes (HieFile (..))
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory)
import System.FilePath (takeExtension, (</>))
import System.IO.Unsafe (unsafeInterleaveIO)

import qualified Data.Map.Strict as Map


{- | From a given path to cabal file and 'HieFile's create the map from modules
(that are in .cabal file) to the resulting parsed extensions for each.
-}
createCabalExtensionsMap
    :: [FilePath]
    -> [HieFile]
    -> IO (Map FilePath (Either ExtensionsError ParsedExtensions))
createCabalExtensionsMap cabalPath hies = case cabalPath of
    -- if cabal files are not specified via CLI option
    -- try to find cabal files in current directory
    [] -> findCabalFiles >>= \case
        -- if cabal file is not found, pass the empty map instead
        [] -> do
            warningMessage ".cabal file not found in the current directory."
            infoMessage " 💡 Try using --cabal-file-path option to specify the path to the .cabal file.\n"
            pure mempty
        -- else concat map for each @.cabal@ file.
        cabals -> fmap mconcat $ mapM getExtensionsWithCabal cabals
    -- if cabal file specified via CLI option
    cabals -> fmap mconcat $ forM (ordNub cabals) $ \cabal ->
        ifM (doesFileExist cabal)
        {- then -} (getExtensionsWithCabal cabal)
        {- else -} (errorMessage (".cabal file does not exist: " <> toText cabal) >> exitFailure)
  where
    getExtensionsWithCabal
        :: FilePath
        -> IO (Map FilePath (Either ExtensionsError ParsedExtensions))
    getExtensionsWithCabal cabal = do
        infoMessage $ "Using the following .cabal file: " <> toText cabal <> "\n"
        (Right <<$>> parseCabalFileExtensions cabal)
            `catch` handleCabalErr
      where
        handleCabalErr
            :: CabalException
            -> IO (Map FilePath (Either ExtensionsError ParsedExtensions))
        handleCabalErr err = do
            errorMessage "Error when parsing cabal file. Stan will continue without information from .cabal file"
            pure $ Map.fromList $
                map (mapToSnd (const $ Left $ CabalError err) . hie_hs_file) hies

{- | Recursively find all @.cabal@ files in the current directory and its
subdirectories. It returns maximum 1 @.cabal@ file from each directory.
-}
findCabalFiles :: IO [FilePath]
findCabalFiles = do
    dir <- getCurrentDirectory
    curDirCabal <- findCabalFileDir dir
    dirs <- getSubdirsRecursive dir
    subDirsCabals <- mapM findCabalFileDir dirs
    pure $ catMaybes $ curDirCabal : subDirsCabals

-- | Find a @.cabal@ file in the given directory.
-- TODO: better error handling in stan.
findCabalFileDir :: FilePath -> IO (Maybe FilePath)
findCabalFileDir dir = do
    dirContent <- listDirectory dir
    let cabalFiles = filter isCabal dirContent
    pure $ case cabalFiles of
        []          -> Nothing -- throwError $ NoCabalFile dirPath
        [cabalFile] -> Just $ dir </> cabalFile
        x:_xs       -> Just x -- throwError $ MultipleCabalFiles (x :| xs)
  where
    isCabal :: FilePath -> Bool
    isCabal p = takeExtension p == ".cabal"

getSubdirsRecursive :: FilePath -> IO [FilePath]
getSubdirsRecursive fp = do
    all' <- filter nonGenDir <$> listDirectory fp
    dirs <- filterM doesDirectoryExist (mkRel <$> all')
    case dirs of
        [] -> pure []
        ds -> do
            next <- unsafeInterleaveIO $ foldMapA getSubdirsRecursive ds
            pure $ dirs ++ next
  where
    nonGenDir :: FilePath -> Bool
    nonGenDir d =
           d /= "dist"
        && d /= "dist-newstyle"
        && d /= ".stack-work"

    mkRel :: FilePath -> FilePath
    mkRel = (fp </>)

mergeParsedExtensions
    :: Either ExtensionsError ParsedExtensions
    -> Either ExtensionsError ParsedExtensions
    -> ExtensionsResult
mergeParsedExtensions (Left err) _                = Left err
mergeParsedExtensions _ (Left err)                = Left err
mergeParsedExtensions (Right exts1) (Right exts2) = mergeAnyExtensions exts1 exts2