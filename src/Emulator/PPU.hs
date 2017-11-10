module Emulator.PPU (
    reset
  , step
) where

import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Bits              (shiftL, shiftR, (.&.), (.|.))
import           Data.IORef
import           Data.Maybe             (fromJust, isJust)
import qualified Data.Vector            as V
import           Data.Word
import           Emulator.Monad
import           Emulator.Nes
import           Emulator.Util
import           Prelude                hiding (cycle)

data RenderPhase
  = RenderVisible Int Int
  | RenderPreFetch
  | RenderIdle
  deriving (Eq, Show)

data VBlankPhase
  = VBlankEnter
  | VBLankIdle
  | VBlankExit
  deriving (Eq, Show)

data FramePhase
  = Render RenderPhase
  | PostRender
  | VBlank VBlankPhase
  deriving (Eq, Show)

data Sprite = Sprite {
  coords        :: Coords,
  tileIndexByte :: Word8,
  attributeByte :: Word8
} deriving (Show, Eq)

data NameTableAddress = NameTableAddress Word8 Word8 Word16 deriving (Show, Eq)

reset :: IOEmulator ()
reset = do
  store (Ppu PpuCycles) 340
  store (Ppu Scanline) 240
  store (Ppu VerticalBlank) False

step :: IOEmulator ()
step = do
  (scanline, cycle) <- tick
  let phase = getFramePhase scanline cycle
  handleFramePhase phase

tick :: IOEmulator Coords
tick = do
  modify (Ppu PpuCycles) (+1)
  cycles <- load $ Ppu PpuCycles

  when (cycles > 340) $ do
    store (Ppu PpuCycles) 0
    modify (Ppu Scanline) (+1)
    scanline <- load (Ppu Scanline)

    when (scanline > 261) $ do
      store (Ppu Scanline) 0
      modify (Ppu FrameCount) (+1)

  scanline <- load $ Ppu Scanline
  cycle <- load $ Ppu PpuCycles
  pure (scanline, cycles)

getFramePhase :: Int -> Int -> FramePhase
getFramePhase scanline cycle
  | scanline >= 0 && scanline <= 239 = Render $ getRenderPhase scanline cycle
  | scanline == 240 = PostRender
  | scanline >= 241 && scanline <= 261 = VBlank $ getVBlankPhase scanline cycle
  | otherwise = error $ "Erronenous frame phase detected at scanline "
    ++ show scanline ++ " and cycle "
    ++ show cycle

getRenderPhase :: Int -> Int -> RenderPhase
getRenderPhase scanline cycle
  | cycle == 0 = RenderIdle
  | cycle >= 1 && cycle <= 256 = RenderVisible scanline cycle
  | cycle >= 321 && cycle <= 336 = RenderPreFetch
  | otherwise = RenderIdle

getVBlankPhase :: Int -> Int -> VBlankPhase
getVBlankPhase scanline cycle
  | scanline == 241 && cycle == 1 = VBlankEnter
  | scanline == 261 && cycle == 1 = VBlankExit
  | otherwise = VBLankIdle

handleFramePhase :: FramePhase -> IOEmulator ()
handleFramePhase phase = case phase of
  Render phase -> handleRenderPhase phase
  VBlank phase -> handleVBlankPhase phase
  PostRender   -> idle

handleRenderPhase :: RenderPhase -> IOEmulator ()
handleRenderPhase phase = case phase of
  RenderVisible scanline cycle -> renderPixel scanline cycle
  other                        -> idle

handleVBlankPhase :: VBlankPhase -> IOEmulator ()
handleVBlankPhase phase = case phase of
  VBlankEnter -> enterVBlank
  VBLankIdle  -> idle
  VBlankExit  -> exitVBlank

renderPixel :: Int -> Int -> IOEmulator ()
renderPixel scanline cycle = do
  coords <- getScrollingCoords scanline cycle
  bgPixelColor <- getBackgroundPixel coords
  store (Ppu $ Screen coords) bgPixelColor

getBackgroundPixel :: Coords -> IOEmulator Color
getBackgroundPixel coords = do
  nametableAddr <- getNametableAddr coords
  tile <- getTile nametableAddr
  patternColor <- getPatternColor tile coords
  attributeColor <- getAttributeColor nametableAddr
  let tileColor = fromIntegral $ (attributeColor `shiftL` 2) .|. patternColor
  paletteIndex <- load $ Ppu $ PpuMemory8 (0x3F00 + tileColor)
  pure $ getPaletteColor paletteIndex

getNametableAddr :: Coords -> IOEmulator NameTableAddress
getNametableAddr (x, y) = do
  base <- load $ Ppu NameTableAddr
  let x' = fromIntegral $ x `div` 8 `mod` 64 `mod` 32 -- not sure
  let y' = fromIntegral $ y `div` 8 `mod` 60 `mod` 30
  pure $ NameTableAddress x' y' base

getTile :: NameTableAddress -> IOEmulator Word8
getTile (NameTableAddress x y base) = load (Ppu $ PpuMemory8 addr)
  where addr = base + 32 * fromIntegral y + fromIntegral x

getPatternColor :: Word8 -> Coords -> IOEmulator Word8
getPatternColor tile (x, y) = do
  let (x', y') = (x `mod` 8, y `mod` 8)

  bgTableAddr <- load $ Ppu BackgroundTableAddr
  let offset = (fromIntegral tile `shiftL` 4) + fromIntegral y' + bgTableAddr

  pattern0 <- load $ Ppu $ PpuMemory8 offset
  pattern1 <- load $ Ppu $ PpuMemory8 $ offset + 8
  let bit0 = (pattern0 `shiftR` (7 - (fromIntegral x' `mod` 8))) .&. 1
  let bit1 = (pattern1 `shiftR` (7 - (fromIntegral x' `mod` 8))) .&. 1

  pure $ (bit1 `shiftL` 1) .|. bit0

getAttributeColor :: NameTableAddress -> IOEmulator Word8
getAttributeColor (NameTableAddress x y base) = do
  let group = fromIntegral $ (y `div` 4 * 8) + (x `div` 4)
  attr <- load $ Ppu $ PpuMemory8 (base + 0x3C0 + group)
  let (left, top) = (x `mod` 4 < 2, y `mod` 4 < 2)
  pure $ case (left, top) of
    (True, True)   -> attr .&. 3
    (False, True)  -> (attr `shiftR` 2) .&. 0x3
    (True, False)  -> (attr `shiftR` 4) .&. 0x3
    (False, False) -> (attr `shiftR` 6) .&. 0x3

getPaletteColor :: Word8 -> Color
getPaletteColor index = palette V.! (fromIntegral index)

getScrollingCoords :: Int -> Int -> IOEmulator Coords
getScrollingCoords scanline cycle = do
  scrollX <- load $ Ppu ScrollX
  scrollY <- load $ Ppu ScrollY
  let x = cycle - 1 + fromIntegral scrollX
  let y = scanline + fromIntegral scrollY
  let x' = if x >= 256 then x - 256 else x
  let y' = if y >= 240 then y - 240 else y
  pure (x', y')

enterVBlank :: IOEmulator ()
enterVBlank = do
  store (Ppu VerticalBlank) True
  generateNMI <- load (Ppu GenerateNMI)
  when generateNMI $ store (Cpu Interrupt) (Just NMI)

exitVBlank :: IOEmulator ()
exitVBlank = store (Ppu VerticalBlank) False

idle :: IOEmulator ()
idle = pure ()

palette :: V.Vector Color
palette = V.fromList
  [ (0x66, 0x66, 0x66), (0x00, 0x2A, 0x88), (0x14, 0x12, 0xA7), (0x3B, 0x00, 0xA4),
    (0x5C, 0x00, 0x7E), (0x6E, 0x00, 0x40), (0x6C, 0x06, 0x00), (0x56, 0x1D, 0x00),
    (0x33, 0x35, 0x00), (0x0B, 0x48, 0x00), (0x00, 0x52, 0x00), (0x00, 0x4F, 0x08),
    (0x00, 0x40, 0x4D), (0x00, 0x00, 0x00), (0x00, 0x00, 0x00), (0x00, 0x00, 0x00),
    (0xAD, 0xAD, 0xAD), (0x15, 0x5F, 0xD9), (0x42, 0x40, 0xFF), (0x75, 0x27, 0xFE),
    (0xA0, 0x1A, 0xCC), (0xB7, 0x1E, 0x7B), (0xB5, 0x31, 0x20), (0x99, 0x4E, 0x00),
    (0x6B, 0x6D, 0x00), (0x38, 0x87, 0x00), (0x0C, 0x93, 0x00), (0x00, 0x8F, 0x32),
    (0x00, 0x7C, 0x8D), (0x00, 0x00, 0x00), (0x00, 0x00, 0x00), (0x00, 0x00, 0x00),
    (0xFF, 0xFE, 0xFF), (0x64, 0xB0, 0xFF), (0x92, 0x90, 0xFF), (0xC6, 0x76, 0xFF),
    (0xF3, 0x6A, 0xFF), (0xFE, 0x6E, 0xCC), (0xFE, 0x81, 0x70), (0xEA, 0x9E, 0x22),
    (0xBC, 0xBE, 0x00), (0x88, 0xD8, 0x00), (0x5C, 0xE4, 0x30), (0x45, 0xE0, 0x82),
    (0x48, 0xCD, 0xDE), (0x4F, 0x4F, 0x4F), (0x00, 0x00, 0x00), (0x00, 0x00, 0x00),
    (0xFF, 0xFE, 0xFF), (0xC0, 0xDF, 0xFF), (0xD3, 0xD2, 0xFF), (0xE8, 0xC8, 0xFF),
    (0xFB, 0xC2, 0xFF), (0xFE, 0xC4, 0xEA), (0xFE, 0xCC, 0xC5), (0xF7, 0xD8, 0xA5),
    (0xE4, 0xE5, 0x94), (0xCF, 0xEF, 0x96), (0xBD, 0xF4, 0xAB), (0xB3, 0xF3, 0xCC),
    (0xB5, 0xEB, 0xF2), (0xB8, 0xB8, 0xB8), (0x00, 0x00, 0x00), (0x00, 0x00, 0x00) ]
