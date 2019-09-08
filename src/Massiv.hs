{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import           Control.Monad             (forM_, replicateM)
import           Control.Monad.ST          (runST)
import           Data.List                 (foldl')
import qualified Data.Massiv.Array         as M
import qualified Data.Massiv.Array.IO      as MIO
import qualified Data.Massiv.Array.Mutable as MM
import           Data.Maybe                (fromMaybe)
import           Data.Proxy                (Proxy (..))
import qualified Graphics.ColorSpace.Y     as Y
import qualified Test.QuickCheck           as QC

newtype Radius   = Radius   {unRadius   :: Float}
newtype Distance = Distance {unDistance :: Float}

data Pulse = Pulse
    { pCenter    :: (Float, Float)
    , pAmplitude :: Float
    , pRadius    :: Radius
    }

data HPulse ix = HPulse
    { hpCenter    :: ix
    , hpAmplitude :: Float
    , hpRadius    :: Radius
    }

unit :: M.Index ix => ix
unit = M.pureIndex 1

(.-.), (.+.) :: M.Index ix => ix -> ix -> ix
(.-.) = M.liftIndex2 (-)
(.+.) = M.liftIndex2 (+)

intersection :: M.Index ix => (ix, ix) -> (ix, ix) -> (ix, ix)
intersection (l1, r1) (l2, r2) =
    (M.liftIndex2 max l1 l2, M.liftIndex2 min r1 r2)

offset :: M.Index ix => ix -> HPulse ix -> HPulse ix
offset o hp = hp {hpCenter = hpCenter hp .-. o}

distance :: M.Index ix => ix -> ix -> Distance
distance i j = Distance . sqrt . fromIntegral .  M.foldlIndex (+) 0 $
    M.liftIndex2 (\p s -> (p - s) * (p - s)) i j

bounds :: M.Index ix => HPulse ix -> (ix, ix)
bounds hp =
    -- TODO (jaspervdj): box calculation
    let radIdx = M.pureIndex . ceiling . (* 1.5) . unRadius $ hpRadius hp
        start  = hpCenter hp .-. radIdx
        end    = hpCenter hp .+. radIdx .+. unit in
    (start, end)

arbitraryIndex :: forall ix. M.Index ix => (Int, Int) -> QC.Gen ix
arbitraryIndex choice = do
    xyzs <- replicateM dim (QC.choose choice)
    return $ foldl'
        (\a (i, c) -> M.setDim' a (M.Dim i) c)
        (M.pureIndex 0)
        (zip [1 ..] xyzs)
  where
    dim = M.unDim $ M.dimensions (Proxy :: Proxy ix)

arbitraryPulse :: M.Index ix => Float -> Int -> QC.Gen (HPulse ix)
arbitraryPulse alpha l = do
    center <- arbitraryIndex (0, l)
    rhoInv <- QC.choose (0.0, 1.0)
    let rho   =  if rhoInv == 0.0 then 1.0 else 1.0 / (1.0 - rhoInv)
        radius = rho / 2.0
        amp    = rho ** (1.0 / alpha)
    ampSign <- QC.elements [-1.0, 1.0]
    return $ HPulse center (ampSign * amp) (Radius radius)

data PulseShape
    = Rectangular
    | Smooth Float    -- s
    | Annuli Float Float  -- lambda, s

pulseAt :: PulseShape -> Distance -> Radius -> Float
pulseAt Rectangular       (Distance u) (Radius r) = if u <= r then 1.0 else 0.0
pulseAt (Smooth s)        (Distance u) (Radius r) = exp (-(u / r) ** (2 * s))
pulseAt (Annuli lambda s) (Distance u) (Radius r) =
    let lambda' = sqrt (lambda * lambda - 1.0)
        delta   = (lambda + lambda') / 2.0
        sigma   = (lambda - lambda') / 2.0 in
    exp (-(((u*u) / (r*r) - (delta*delta)) / (sigma*sigma)) ** (2 * s))

drawPulse
    :: forall ix r m. (MM.Mutable r ix Float, M.PrimMonad m, M.MonadThrow m)
    => MM.MArray (M.PrimState m) r ix Float
    -> PulseShape
    -> HPulse ix
    -> m ()
drawPulse marr shape pulse = M.iterM_ i0 end unit (<) $ \i -> MM.modifyM
    marr
    (\x -> pure $
        x + pulseAt shape (distance i (hpCenter pulse)) (hpRadius pulse))
    i
  where
    pulseBounds = bounds pulse
    marrBounds  = (M.pureIndex 0, M.unSz (M.msize marr))
    (i0, end)   = intersection pulseBounds marrBounds
    -- bimap repair repair $ bounds pulse :: (ix, ix)

normalize
    :: (Functor (M.Array r ix), M.Source r ix Float)
    => M.Array r ix Float -> M.Array r ix Float
normalize arr =
    let (mini, maxi) = (M.minimum' arr, M.maximum' arr) in
    (\x -> (x - mini) / (maxi - mini)) <$> arr

treshold
    :: forall r ix. (Functor (M.Array r ix), M.Source r ix Float)
    => Float -> M.Array r ix Float -> M.Array r ix Float
treshold relativeTreshold arr =
    (\x ->
        if x < absoluteTreshold
            then 0.0
            else (x - absoluteTreshold) / (1.0 - absoluteTreshold)) <$> arr
  where
    numBuckets = 100

    histogram :: M.Array M.P Int Int
    histogram = runST $ do
        marr <- MM.makeMArrayS (M.Sz numBuckets + 1) (\_ -> pure 0)
        M.forM_ arr $ \x ->
            let b = floor (x * fromIntegral numBuckets) in
            MM.modifyM marr (pure . succ) b
        MM.freezeS marr

    absoluteTreshold =
        let target = floor $
                relativeTreshold * fromIntegral (M.totalElem (M.size arr))
            go acc i
                | i >= numBuckets = 1.0
                | otherwise       =
                    let acc' = acc + fromMaybe 0 (M.index histogram i) in
                    if acc' >= target
                        then fromIntegral i / fromIntegral numBuckets
                        else go acc' (i + 1)  in
        go 0 0

main :: IO ()
main = do
    let fsize   = 3 * size :: Int
        size    = 400
        off     = 400
        shape   = Smooth 4
        v       = 10
        npulses = size * size * v
        alpha   = 5 / 3
        r0      = 0.7

    pulses <- QC.generate $ replicateM npulses $ arbitraryPulse alpha fsize
    marr   <- MM.makeMArray (M.ParN 0) (M.Sz (M.pureIndex size)) (\_ -> pure 0)
    forM_ (map (offset off) pulses) $ drawPulse marr shape
    arr <- MM.freeze (M.ParN 0) marr :: IO (M.Array M.P M.Ix2 Float)
    MIO.writeImageAuto "massiv.png" $ fmap Y.PixelY $ treshold r0 $ normalize $
        M.delay arr