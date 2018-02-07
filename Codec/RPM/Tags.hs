{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module: Codec.RPM.Tags
-- Copyright: (c) 2016-2017 Red Hat, Inc.
-- License: LGPL
--
-- Maintainer: https://github.com/weldr
-- Stability: stable
-- Portability: portable

module Codec.RPM.Tags(
    -- * Types
    Tag(..),
    Null(..),
    -- * Tag finding functions
    findTag,
    findByteStringTag,
    findStringTag,
    findStringListTag,
    findWord16Tag,
    findWord16ListTag,
    findWord32Tag,
    findWord32ListTag,
    -- * Tag making functions
    mkTag,
    -- * Tag inspection functions
    tagValue)
 where

import           Data.Bits((.&.), shiftR)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C
import           Data.Data(showConstr, toConstr)
import           Data.List(find)
import           Data.Maybe(fromMaybe, listToMaybe)
import           Data.Word

import Codec.RPM.Internal.Numbers
import Codec.RPM.Internal.Tags
import Codec.RPM.Internal.Tags.TH

{-# ANN module "HLint: ignore Use camelCase" #-}

-- The character lists are actually lists of characters, ignore the suggestions
-- to use String instead
{-# ANN module "HLint: ignore Use String" #-}

-- | Attempt to create a 'Tag' based on various parameters.
mkTag :: BS.ByteString      -- ^ The 'headerStore' containing the value of the potential 'Tag'.
      -> Int                -- ^ The number of the 'Tag', as read out of the store.  Valid numbers
                            --   may be found in lib\/rpmtag.h in the RPM source, though most
                            --   users will not need to know this since it will be read from the
                            --   store.
      -> Word32             -- ^ What is the type of this tag's value?  Valid numbers may be found
                            --   in the rpmTagType_e enum in lib\/rpmtag.h in the RPM source, though
                            --   most users will not need to know this since it will be read from
                            --   the store.  Here, it is used as a simple form of type checking.
      -> Word32             -- ^ How far into the 'headerStore' is this 'Tag's value stored?
      -> Word32             -- ^ How many values are stored for this 'Tag'?
      -> Maybe Tag

-- Create the actual function via TemplateHaskell from the tagLibrary descriptions
mkTag = $(createMkTagTmpl)

mkNull :: BS.ByteString -> Word32 -> Word32 -> Word32 -> Maybe Null
mkNull _ ty _ _ | ty == 0    = Just Null
                | otherwise  = Nothing

mkChar :: BS.ByteString -> Word32 -> Word32 -> Word32 -> Maybe [Char]
mkChar store ty offset count | fromIntegral (BS.length store) - offset < count = Nothing
                             | ty == 1   = Just $ C.unpack $ BS.take count' start
                             | otherwise = Nothing
 where
    count' = fromIntegral count
    start = BS.drop (fromIntegral offset) store

mkWord16 :: BS.ByteString -> Word32 -> Word32 -> Word32 -> Maybe [Word16]
mkWord16 store ty offset count | fromIntegral (BS.length store) - offset < (2*count) = Nothing
                               | ty == 3     = Just $ readWords store 2 asWord16 offsets
                               | otherwise   = Nothing
 where
    offsets = map (\n -> offset + (n*2)) [0 .. count-1]

mkWord32 :: BS.ByteString -> Word32 -> Word32 -> Word32 -> Maybe [Word32]
mkWord32 store ty offset count | fromIntegral (BS.length store) - offset < (4*count) = Nothing
                               | ty == 4     = Just $ readWords store 4 asWord32 offsets
                               | otherwise   = Nothing
 where
    offsets = map (\n -> offset + (n*4)) [0 .. count-1]

mkWord64 :: BS.ByteString -> Word32 -> Word32 -> Word32 -> Maybe [Word64]
mkWord64 store ty offset count | fromIntegral (BS.length store) - offset < (8*count) = Nothing
                               | ty == 5     = Just $ readWords store 8 asWord64 offsets
                               | otherwise   = Nothing
 where
    offsets = map (\n -> offset + (n*8)) [0 .. count-1]

mkString :: BS.ByteString -> Word32 -> Word32 -> Word32 -> Maybe String
mkString store ty offset count | fromIntegral (BS.length store) - offset < count = Nothing
                               | ty == 6   = Just $ C.unpack $ BS.takeWhile (/= 0) start
                               | otherwise = Nothing
 where
    start = BS.drop (fromIntegral offset) store

mkBinary :: BS.ByteString -> Word32 -> Word32 -> Word32 -> Maybe BS.ByteString
mkBinary store ty offset count | fromIntegral (BS.length store) - offset < count = Nothing
                               | ty == 7     = Just $ BS.take count' start
                               | otherwise   = Nothing
 where
    count' = fromIntegral count
    start  = BS.drop (fromIntegral offset) store

mkStringArray :: BS.ByteString -> Word32 -> Word32 -> Word32 -> Maybe [String]
mkStringArray store ty offset count | fromIntegral (BS.length store) - offset < count = Nothing
                                    | ty == 8    = Just $ map C.unpack $ readStrings start count
                                    | otherwise  = Nothing
 where
    start = BS.drop (fromIntegral offset) store

mkI18NString :: BS.ByteString -> Word32 -> Word32 -> Word32 -> Maybe BS.ByteString
mkI18NString store ty offset count | fromIntegral (BS.length store) - offset < count = Nothing
                                   | ty == 9     = Just $ BS.takeWhile (/= 0) start
                                   | otherwise   = Nothing
 where
    start  = BS.drop (fromIntegral offset) store

-- I don't know how to split a ByteString up into chunks of a given size, so here's what I'm doing.  Take
-- a list of offsets of where in the ByteString to read.  Skip to each of those offsets, grab size bytes, and
-- convert those bytes into the type using the given conversion function.  Return that list.
{-# ANN readWords "HLint: ignore Eta reduce" #-}
readWords :: BS.ByteString -> Int -> (BS.ByteString -> a) -> [Word32] -> [a]
readWords bs size conv offsets = map (\offset -> conv $ BS.take size $ BS.drop (fromIntegral offset) bs) offsets

readStrings :: BS.ByteString -> Word32 -> [BS.ByteString]
readStrings bytestring count  = take (fromIntegral count) $ BS.split 0 bytestring

-- | Given the name of a 'Tag' and a list of 'Tag's (say, from the 'Codec.RPM.Types.Header' of some
-- 'Codec.RPM.Types.RPM'), find the match and return it as a 'Maybe'.  This is the most generic of
-- the various finding functions - it will return any match regardless of its type.  You are
-- expected to know what type you are looking for.
findTag :: String -> [Tag] -> Maybe Tag
findTag name = find (\t -> name == showConstr (toConstr t))

-- | Given the name of a 'Tag' and a list of 'Tag's, find the match, convert it into a
-- 'ByteString', and return it as a 'Maybe'.  If the value of the 'Tag' cannot be converted
-- into a 'ByteString' (say, because it is of the wrong type), 'Nothing' will be returned.
-- Thus, this should only be used on tags whose value is known - see the definition of 'Tag'
-- for the possibilities.
findByteStringTag :: String -> [Tag] -> Maybe BS.ByteString
findByteStringTag name tags = findTag name tags >>= \t -> tagValue t :: Maybe BS.ByteString

-- | Given the name of a 'Tag' and a list of 'Tag's, find the match, convert it into a
-- 'String', and return it as a 'Maybe'.  If the value of the 'Tag' cannot be converted
-- into a 'String' (say, because it is of the wrong type), 'Nothing' will be returned.
-- Thus, this should only be used on tags whose value is known - see the definition of
-- 'Tag' for the possibilities.
findStringTag :: String -> [Tag] -> Maybe String
findStringTag name tags = findTag name tags >>= \t -> tagValue t :: Maybe String

-- | Given the name of a 'Tag' and a list of 'Tag's, find all matches, convert them into
-- 'String's, and return a list.  If no results are found or the value of a single 'Tag'
-- cannot be converted into a 'String' (say, because it is of the wrong type), an empty
-- list will be returned.  Thus, this should only be used on tags whose value is known -
-- see the definition of 'Tag' for the possibilities.
findStringListTag :: String -> [Tag] -> [String]
findStringListTag name tags = fromMaybe [] $ findTag name tags >>= \t -> tagValue t :: Maybe [String]

-- | Given the name of a 'Tag' and a list of 'Tag's, find the match, convert it into a
-- 'Word16', and return it as a 'Maybe'.  If the value of the 'Tag' cannot be converted
-- into a 'Word16' (say, because it is of the wrong type), 'Nothing' will be returned.
-- Thus, this should only be used on tags whose value is known - see the definition of 'Tag'
-- for the possibilities.
findWord16Tag :: String -> [Tag] -> Maybe Word16
findWord16Tag name tags = findTag name tags >>= \t -> tagValue t :: Maybe Word16

-- | Given the name of a 'Tag' and a list of 'Tag's, find all matches, convert them into
-- 'Word16's, and return a list.  If no results are found or the value of a single 'Tag'
-- cannot be converted into a 'Word16' (say, because it is of the wrong type), an empty
-- list will be returned.  Thus, this should only be used on tags whose value is known -
-- see the definition of 'Tag' for the possibilities.
findWord16ListTag :: String -> [Tag] -> [Word16]
findWord16ListTag name tags = fromMaybe [] $ findTag name tags >>= \t -> tagValue t :: Maybe [Word16]

-- | Given the name of a 'Tag' and a list of 'Tag's, find the match, convert it into a
-- 'Word16', and return it as a 'Maybe'.  If the value of the 'Tag' cannot be converted
-- into a 'Word16' (say, because it is of the wrong type), 'Nothing' will be returned.
-- Thus, this should only be used on tags whose value is known - see the definition of 'Tag'
-- for the possibilities.
findWord32Tag :: String -> [Tag] -> Maybe Word32
findWord32Tag name tags = findTag name tags >>= \t -> tagValue t :: Maybe Word32

-- | Given the name of a 'Tag' and a list of 'Tag's, find all matches, convert them into
-- 'Word32's, and return a list.  If no results are found or the value of a single 'Tag'
-- cannot be converted into a 'Word32' (say, because it is of the wrong type), an empty
-- list will be returned.  Thus, this should only be used on tags whose value is known -
-- see the definition of 'Tag' for the possibilities.
findWord32ListTag :: String -> [Tag] -> [Word32]
findWord32ListTag name tags = fromMaybe [] $ findTag name tags >>= \t -> tagValue t :: Maybe [Word32]
