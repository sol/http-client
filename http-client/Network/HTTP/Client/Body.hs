{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.HTTP.Client.Body
    ( makeGzipReader
    , brConsume
    , brEmpty
    , brAddCleanup
    , brReadSome
    , brRead
    ) where

import Network.HTTP.Client.Types
import Control.Exception (throwIO)
import Data.IORef
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import Control.Monad (when)
import qualified Data.Streaming.Zlib as Z

-- ^ Get a single chunk of data from the response body, or an empty
-- bytestring if no more data is available.
--
-- Since 0.1.0
brRead :: BodyReader -> IO S.ByteString
brRead = id

brReadSome :: BodyReader -> Int -> IO L.ByteString
brReadSome brRead =
    loop id
  where
    loop front rem
        | rem <= 0 = return $ L.fromChunks $ front []
        | otherwise = do
            bs <- brRead
            if S.null bs
                then return $ L.fromChunks $ front []
                else loop (front . (bs:)) (rem - S.length bs)

brEmpty :: BodyReader
brEmpty = return S.empty

brAddCleanup :: IO () -> BodyReader -> BodyReader
brAddCleanup cleanup brRead = do
    bs <- brRead
    when (S.null bs) cleanup
    return bs

-- | Strictly consume all remaining chunks of data from the stream.
--
-- Since 0.1.0
brConsume :: BodyReader -> IO [S.ByteString]
brConsume brRead =
    go id
  where
    go front = do
        x <- brRead
        if S.null x
            then return $ front []
            else go (front . (x:))

makeGzipReader :: BodyReader -> IO BodyReader
makeGzipReader brRead = do
    inf <- Z.initInflate $ Z.WindowBits 31
    istate <- newIORef Nothing
    let goPopper popper = do
            res <- popper
            case res of
                Z.PRNext bs -> do
                    writeIORef istate $ Just popper
                    return bs
                Z.PRDone -> do
                    bs <- Z.flushInflate inf
                    if S.null bs
                        then start
                        else do
                            writeIORef istate Nothing
                            return bs
                Z.PRError e -> throwIO $ HttpZlibException e
        start = do
            bs <- brRead
            if S.null bs
                then return S.empty
                else do
                    popper <- Z.feedInflate inf bs
                    goPopper popper
    return $ do
        state <- readIORef istate
        case state of
            Nothing -> start
            Just popper -> goPopper popper
