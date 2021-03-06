
\subsection{Cardano.BM.Backend.Log}
\label{code:Cardano.BM.Backend.Log}

%if style == newcode
\begin{code}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.BM.Backend.Log
    (
      Log
    , effectuate
    , realize
    , unrealize
    , registerScribe
    , sev2klog
    -- * re-exports
    , K.Scribe
    ) where

import           Control.AutoUpdate (UpdateSettings (..), defaultUpdateSettings,
                     mkAutoUpdate)
import           Control.Concurrent.MVar (MVar, modifyMVar_, readMVar,
                     newMVar, withMVar)
import           Control.Exception.Safe (catchIO)
import           Control.Monad (foldM, forM_, unless, when, void)
import           Control.Lens ((^.))
import           Data.Aeson (FromJSON, ToJSON, Result (Success), Value (..),
                     encode, fromJSON, toJSON)
import           Data.Aeson.Text (encodeToLazyText)
import qualified Data.HashMap.Strict as HM
import qualified Data.Map as Map
import           Data.List (find)
import           Data.Maybe (isNothing)
import           Data.String (fromString)
import           Data.Text (Text, isPrefixOf, pack, unpack)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import           Data.Text.Lazy.Builder (Builder, fromText, toLazyText)
import qualified Data.Text.Lazy.IO as TIO
import           Data.Time (diffUTCTime)
import           Data.Time.Clock (UTCTime, getCurrentTime)
import           Data.Time.Format (defaultTimeLocale, formatTime)
import           GHC.Conc (atomically)
import           GHC.IO.Handle (hDuplicate)
import           System.Directory (createDirectoryIfMissing)
import           System.FilePath (takeDirectory)
import           System.IO (BufferMode (LineBuffering), Handle, hClose,
                     hSetBuffering, stderr, stdout, openFile, IOMode (WriteMode))

import qualified Katip as K
import qualified Katip.Core as KC
import           Katip.Scribes.Handle (brackets)

import qualified Cardano.BM.Configuration as Config
import           Cardano.BM.Configuration.Model (getScribes, getSetupScribes)
import           Cardano.BM.Data.Aggregated
import           Cardano.BM.Data.Backend
import           Cardano.BM.Data.LogItem
import           Cardano.BM.Data.Output
import           Cardano.BM.Data.Rotation (RotationParameters (..))
import           Cardano.BM.Data.Severity
import           Cardano.BM.Rotator (cleanupRotator, evalRotator,
                     initializeRotator, prtoutException)

\end{code}
%endif

\subsubsection{Internal representation}\label{code:Log}\index{Log}
\begin{code}
type LogMVar = MVar LogInternal
newtype Log a = Log
    { getK :: LogMVar }

data LogInternal = LogInternal
    { kLogEnv       :: K.LogEnv
    , configuration :: Config.Configuration }

\end{code}

\subsubsection{Log implements |effectuate|}\index{Log!instance of IsEffectuator}
\begin{code}
instance ToJSON a => IsEffectuator Log a where
    effectuate katip item = do
        let logMVar = getK katip
        c <- configuration <$> readMVar logMVar
        setupScribes <- getSetupScribes c
        selscribes <- getScribes c (loName item)
        let selscribesFiltered =
                case item of
                    LogObject _ (LOMeta _ _ _ _ Confidential) (LogMessage _)
                        -> removePublicScribes setupScribes selscribes
                    _   -> selscribes
        forM_ selscribesFiltered $ \sc -> passN sc katip item
      where
        removePublicScribes allScribes = filter $ \sc ->
            let (_, nameD) = T.breakOn "::" sc
                -- drop "::" from the start of name
                name = T.drop 2 nameD
            in
            case find (\x -> scName x == name) allScribes of
                Nothing     -> False
                Just scribe -> scPrivacy scribe == ScPrivate
    handleOverflow _ = TIO.hPutStrLn stderr "Notice: Katip's queue full, dropping log items!"

\end{code}

\subsubsection{Log implements backend functions}\index{Log!instance of IsBackend}
\begin{code}
instance (ToJSON a, FromJSON a) => IsBackend Log a where
    bekind _ = KatipBK

    realize config = do
        let updateEnv :: K.LogEnv -> IO UTCTime -> K.LogEnv
            updateEnv le timer =
                le { K._logEnvTimer = timer, K._logEnvHost = "hostname" }
        ver <- Config.getTextOptionOrDefault config "appversion" "<unknown>"
        commit <- Config.getTextOptionOrDefault config "appcommit" "00000"
        le0 <- K.initLogEnv
                    (K.Namespace mempty)
                    (fromString $ unpack ver <> ":" <> take 5 (unpack commit))
        -- request a new time 'getCurrentTime' at most 100 times a second
        timer <- mkAutoUpdate defaultUpdateSettings { updateAction = getCurrentTime, updateFreq = 10000 }
        let le1 = updateEnv le0 timer
        scribes <- getSetupScribes config
        le <- registerScribes scribes le1

        kref <- newMVar $ LogInternal le config

        return $ Log kref

    unrealize katip = do
        le <- withMVar (getK katip) $ \k -> return (kLogEnv k)
        void $ K.closeScribes le

\end{code}

\subsubsection{Create and register \emph{katip} scribes}
\begin{code}
registerScribe :: Log a -> K.Scribe -> ScribeId -> IO ()
registerScribe katip scr name =
    modifyMVar_ (getK katip) $ \k -> do
        newenv <- K.registerScribe name scr scribeSettings (kLogEnv k)

        return $ k { kLogEnv = newenv }


scribeSettings :: KC.ScribeSettings
scribeSettings =
    let bufferSize = 5000  -- size of the queue (in log items)
    in
    KC.ScribeSettings bufferSize

registerScribes :: [ScribeDefinition] -> K.LogEnv -> IO K.LogEnv
registerScribes defscs le =
    foldM withScribeInEnv le defscs
  where
    withScribeInEnv :: K.LogEnv -> ScribeDefinition -> IO K.LogEnv
    withScribeInEnv le' defsc = do
            let kind = scKind defsc
                sctype = scFormat defsc
                name = scName defsc
                rotParams = scRotation defsc
                name' = pack (show kind) <> "::" <> name
            scribe <- createScribe kind sctype name rotParams
            case scribe of
                Just scr -> K.registerScribe name' scr scribeSettings le'
                Nothing -> return le'

    createScribe FileSK ScText name rotParams = Just <$> mkTextFileScribe
                                                    rotParams
                                                    (FileDescription $ unpack name)
                                                    False
    createScribe FileSK ScJson name rotParams = Just <$> mkJsonFileScribe
                                                    rotParams
                                                    (FileDescription $ unpack name)
                                                    False
    createScribe StdoutSK sctype _ _ = Just <$> mkStdoutScribe sctype
    createScribe StderrSK sctype _ _ = Just <$> mkStderrScribe sctype
    createScribe DevNullSK _ _ _ = Just <$> mkDevNullScribe
    createScribe JournalSK _ _ _ = return Nothing
    createScribe UserDefinedSK ty nm rot = createScribe FileSK ty nm rot

\end{code}


\begin{spec}
example :: IO ()
example = do
    config <- Config.setup "from_some_path.yaml"
    k <- setup config
    meta <- mkLOMeta Info Public
    passN (pack (show StdoutSK)) k $ LogObject
                                            { loName = ["test"]
                                            , loMeta = meta
                                            , loContent = LogMessage "Hello!"
                                            }
    meta' <- mkLOMeta Info Public
    passN (pack (show StdoutSK)) k $ LogObject
                                            { loName = ["test"]
                                            , loMeta = meta'
                                            , loContent = LogValue "cpu-no" 1
                                            }

\end{spec}

Needed instances for |katip|:
\begin{code}
deriving instance ToJSON a => K.ToObject (LogObject a)
deriving instance K.ToObject Text
deriving instance ToJSON a => K.ToObject (LOContent a)
deriving instance K.ToObject Value
deriving instance ToJSON a => K.ToObject (Maybe (LOContent a))
instance (ToJSON a, ToJSON b, K.ToObject a, K.ToObject b) => K.ToObject (Maybe (Either a b)) where
  toObject Nothing = mempty
  toObject (Just (Left  x)) = KC.toObject x
  toObject (Just (Right x)) = KC.toObject x

instance (ToJSON a, ToJSON b, K.ToObject a, K.ToObject b) => KC.LogItem (Maybe (Either a b)) where
    payloadKeys _ _ = KC.AllKeys
instance ToJSON a => KC.LogItem (LogObject a) where
    payloadKeys _ _ = KC.AllKeys
instance KC.LogItem Text where
    payloadKeys _ _ = KC.AllKeys
instance ToJSON a => KC.LogItem (Maybe (LOContent a)) where
    payloadKeys _ _ = KC.AllKeys

\end{code}

\subsubsection{Log.passN}\label{code:passN}
The following function copies the |LogObject| to the queues of all scribes
that match on their name.
Compare start of name of scribe to |(show backend <> "::")|.
This function is non-blocking.
\begin{code}
passN :: forall a. ToJSON a => ScribeId -> Log a -> LogObject a -> IO ()
passN backend katip (LogObject loname lometa loitem) = do
    env <- kLogEnv <$> readMVar (getK katip)
    forM_ (Map.toList $ K._logEnvScribes env) $
          \(scName, (KC.ScribeHandle _ shChan)) ->
              -- check start of name to match |ScribeKind|
                when (backend `isPrefixOf` scName) $ do
                    let payload :: Maybe (Either (LOContent a) Value)
                        (sev, msg, payload) = case loitem of
                                (LogMessage logItem) ->
                                     let (text,maylo) = case toJSON logItem of
                                            (String m)  -> (m, Nothing)
                                            m           -> (TL.toStrict $ encodeToLazyText m, Nothing)
                                     in
                                     (severity lometa, text, maylo)
                                (LogError text) ->
                                     (severity lometa, text, Just $ Left loitem)
                                (LogStructured s) ->
                                     (severity lometa, "", Just . Right $ Object s)
                                (LogValue name value) ->
                                    if name == ""
                                    then (severity lometa, pack (showSI value), Just $ Left loitem)
                                    else (severity lometa, name <> " = " <> pack (showSI value), Just $ Left loitem)
                                (ObserveDiff _) ->
                                     let text = TL.toStrict (encodeToLazyText loitem)
                                     in
                                     (severity lometa, text, Just $ Left loitem)
                                (ObserveOpen _) ->
                                     let text = TL.toStrict (encodeToLazyText loitem)
                                     in
                                     (severity lometa, text, Just $ Left loitem)
                                (ObserveClose _) ->
                                     let text = TL.toStrict (encodeToLazyText loitem)
                                     in
                                     (severity lometa, text, Just $ Left loitem)
                                (AggregatedMessage aggregated) ->
                                     let text = T.concat $ flip map aggregated $ \(name, agg) ->
                                                "\n" <> name <> ": " <> pack (show agg)
                                    in
                                    (severity lometa, text, Just $ Left loitem)
                                (MonitoringEffect _) ->
                                     let text = TL.toStrict (encodeToLazyText loitem)
                                     in
                                     (severity lometa, text, Just $ Left loitem)
                                KillPill ->
                                    (severity lometa, "Kill pill received!", Nothing)
                                Command _ ->
                                    (severity lometa, "Command received!", Nothing)
                    unless (msg == "" && isNothing payload) $ do
                        let threadIdText = KC.ThreadIdText $ tid lometa
                        let itemTime = tstamp lometa
                        let localname = [loname]
                        let itemKatip = K.Item {
                                  _itemApp       = env ^. KC.logEnvApp
                                , _itemEnv       = env ^. KC.logEnvEnv
                                , _itemSeverity  = sev2klog sev
                                , _itemThread    = threadIdText
                                , _itemHost      = unpack $ hostname lometa
                                , _itemProcess   = env ^. KC.logEnvPid
                                , _itemPayload   = payload
                                , _itemMessage   = K.logStr msg
                                , _itemTime      = itemTime
                                , _itemNamespace = env ^. KC.logEnvApp <> K.Namespace localname
                                , _itemLoc       = Nothing
                                }
                        void $ atomically $ KC.tryWriteTBQueue shChan (KC.NewItem itemKatip)
\end{code}

\subsubsection{Scribes}
The handles to \emph{stdout} and \emph{stderr} will be duplicated
because on exit \emph{katip} will close them otherwise.

\begin{code}
mkStdoutScribe :: ScribeFormat -> IO K.Scribe
mkStdoutScribe ScText = do
    stdout' <- hDuplicate stdout
    mkTextFileScribeH stdout' True
mkStdoutScribe ScJson = do
    stdout' <- hDuplicate stdout
    mkJsonFileScribeH stdout' True

mkStderrScribe :: ScribeFormat -> IO K.Scribe
mkStderrScribe ScText = do
    stderr' <- hDuplicate stderr
    mkTextFileScribeH stderr' True
mkStderrScribe ScJson = do
    stderr' <- hDuplicate stderr
    mkJsonFileScribeH stderr' True

mkDevNullScribe :: IO K.Scribe
mkDevNullScribe = do
    let logger _ = pure ()
    pure $ K.Scribe logger (pure ()) (pure . const True)

type Formatter a = K.LogItem a => Handle -> Rendering a -> IO Int

textFormatter, jsonFormatter :: Formatter a
textFormatter h r =
  let (len, msg) = renderTextMsg r
  in (TIO.hPutStrLn h $! msg) >> pure len
jsonFormatter h r =
  let (len, msg) = renderJsonMsg r
  in (TIO.hPutStrLn h $! msg) >> pure len

mkTextFileScribeH, mkJsonFileScribeH :: Handle -> Bool -> IO K.Scribe
mkTextFileScribeH = mkFileScribeH textFormatter
mkJsonFileScribeH = mkFileScribeH jsonFormatter

mkTextFileScribe, mkJsonFileScribe :: Maybe RotationParameters -> FileDescription -> Bool -> IO K.Scribe
mkTextFileScribe = mkFileScribe textFormatter
mkJsonFileScribe = mkFileScribe jsonFormatter

mkFileScribeH
    :: (forall a. Formatter a)
    -> Handle
    -> Bool
    -> IO K.Scribe
mkFileScribeH formatter h colorize = do
    hSetBuffering h LineBuffering
    locklocal <- newMVar ()
    let logger :: forall a. K.LogItem a =>  K.Item a -> IO ()
        logger item = withMVar locklocal $ \_ ->
                        void $ formatter h (Rendering colorize K.V0 item)
    pure $ K.Scribe logger (hClose h) (pure . const True)

data Rendering a = Rendering { colorize  :: Bool
                             , verbosity :: K.Verbosity
                             , logitem   :: K.Item a
                             }

renderTextMsg :: (K.LogItem a) => Rendering a -> (Int, TL.Text)
renderTextMsg r =
    let li = logitem r
        m = toLazyText $ formatItem (colorize r) (verbosity r) $
            case KC._itemMessage li of
              K.LogStr ""  -> li { KC._itemMessage = K.logStr . encode . K.toObject $ KC._itemPayload li }
              _ -> li
    in (fromIntegral $ TL.length m, m)

renderJsonMsg :: (K.LogItem a) => Rendering a -> (Int, TL.Text)
renderJsonMsg r =
    let li = logitem r
        li' = li { KC._itemMessage = "" }
        m' = encodeToLazyText $ trimTime $ K.itemJson (verbosity r) li'
    in (fromIntegral $ TL.length m', m')

-- keep only two digits for the fraction of seconds
trimTime :: Value -> Value
trimTime (Object o) = Object $ HM.adjust
                                keep2Decimals
                                "at"
                                o
  where
    keep2Decimals :: Value -> Value
    keep2Decimals v = case fromJSON v of
                        Success (utct :: UTCTime) ->
                            String $ pack $ formatTime defaultTimeLocale jformat utct
                        _ -> v
    jformat :: String
    jformat = "%FT%T%2QZ"
trimTime v = v

mkFileScribe
    :: (forall a . K.LogItem a => Handle -> Rendering a -> IO Int)
    -> Maybe RotationParameters
    -> FileDescription
    -> Bool
    -> IO K.Scribe
mkFileScribe formatter (Just rotParams) fdesc colorize = do
    let prefixDir = prefixPath fdesc
    createDirectoryIfMissing True prefixDir
        `catchIO` prtoutException ("cannot log prefix directory: " ++ prefixDir)
    let fpath = filePath fdesc
    trp <- initializeRotator rotParams fpath
    scribestate <- newMVar trp  -- triple of (handle), (bytes remaining), (rotate time)
    -- sporadically remove old log files - every 10 seconds
    cleanup <- mkAutoUpdate defaultUpdateSettings {
                                updateAction = cleanupRotator rotParams fpath
                              , updateFreq = 10000000
                              }
    let finalizer :: IO ()
        finalizer = withMVar scribestate $
                                \(h, _, _) -> hClose h
    let logger :: forall a. K.LogItem a => K.Item a -> IO ()
        logger item =
            modifyMVar_ scribestate $ \(h, bytes, rottime) -> do
                byteswritten <- formatter h (Rendering colorize K.V0 item)
                -- remove old files
                cleanup
                -- detect log file rotation
                let bytes' = bytes - toInteger byteswritten
                let tdiff' = round $ diffUTCTime rottime (K._itemTime item)
                if bytes' < 0 || tdiff' < (0 :: Integer)
                    then do   -- log file rotation
                        hClose h
                        (h2, bytes2, rottime2) <- evalRotator rotParams fpath
                        return (h2, bytes2, rottime2)
                    else
                        return (h, bytes', rottime)
    return $ K.Scribe logger finalizer (pure . const True)
-- log rotation disabled.
mkFileScribe formatter Nothing fdesc colorize = do
    let prefixDir = prefixPath fdesc
    createDirectoryIfMissing True prefixDir
        `catchIO` prtoutException ("cannot create prefix directory: " ++ prefixDir)
    let fpath = filePath fdesc
    h <- catchIO (openFile fpath WriteMode) $
                        \e -> do
                            prtoutException ("error while opening log: " ++ fpath) e
                            -- fallback to standard output in case of exception
                            return stdout
    hSetBuffering h LineBuffering
    scribestate <- newMVar h
    let finalizer :: IO ()
        finalizer = withMVar scribestate hClose
    let logger :: forall a. K.LogItem a => K.Item a -> IO ()
        logger item =
            withMVar scribestate $ \handler ->
                void $ formatter handler (Rendering colorize K.V0 item)
    return $ K.Scribe logger finalizer (pure . const True)

\end{code}

\begin{code}
formatItem :: Bool -> K.Verbosity -> K.Item a -> Builder
formatItem withColor _verb K.Item{..} =
    fromText header <>
    fromText " " <>
    brackets (fromText timestamp) <>
    fromText " " <>
    KC.unLogStr _itemMessage
  where
    header = colorBySeverity _itemSeverity $
             "[" <> hostname <> mconcat namedcontext <> ":" <> severity <> ":" <> threadid <> "]"
    hostname | _itemHost == "" = ""
             | otherwise = pack _itemHost <> ":"
    namedcontext = KC.intercalateNs _itemNamespace
    severity = KC.renderSeverity _itemSeverity
    threadid = KC.getThreadIdText _itemThread
    timestamp = pack $ formatTime defaultTimeLocale tsformat _itemTime
    tsformat :: String
    tsformat = "%F %T%2Q %Z"
    colorBySeverity s m = case s of
      K.EmergencyS -> red m
      K.AlertS     -> red m
      K.CriticalS  -> red m
      K.ErrorS     -> red m
      K.NoticeS    -> magenta m
      K.WarningS   -> yellow m
      K.InfoS      -> blue m
      _          -> m
    red = colorize "31"
    yellow = colorize "33"
    magenta = colorize "35"
    blue = colorize "34"
    colorize c m
      | withColor = "\ESC["<> c <> "m" <> m <> "\ESC[0m"
      | otherwise = m

-- translate Severity to Log.Severity
sev2klog :: Severity -> K.Severity
sev2klog = \case
    Debug     -> K.DebugS
    Info      -> K.InfoS
    Notice    -> K.NoticeS
    Warning   -> K.WarningS
    Error     -> K.ErrorS
    Critical  -> K.CriticalS
    Alert     -> K.AlertS
    Emergency -> K.EmergencyS

\end{code}

\begin{code}
newtype FileDescription = FileDescription { filePath :: FilePath }
  deriving (Show)

prefixPath :: FileDescription -> FilePath
prefixPath = takeDirectory . filePath

\end{code}
