#!/usr/bin/env python3
"""
CVBasic Pletter Compression Tool

Converts raw CVBasic DATA sections into Pletter-compressed chunks.

Copyright (c) 2025 Troy Schrapel
License: MIT
GitHub: https://github.com/visrealm/retroplex

==============================================================================
USAGE
==============================================================================

python cvpletter.py <input.bas> [output.bas] [-o output_dir]

ARGUMENTS:
  <input.bas>     Required. Input CVBasic file containing labeled DATA BYTE
                  sections to be compressed.

  [output.bas]    Optional. Explicit output file path. If not specified,
                  generates output in same directory as input with
                  ".pletter.bas" extension.

  -o output_dir   Optional. Output directory for generated files. Cannot be
                  used with explicit output.bas path.

EXAMPLES:
  python cvpletter.py levels.bas
  python cvpletter.py levels.bas levels.pletter.bas
  python cvpletter.py levels.bas -o ../build

==============================================================================
PRAGMA DIRECTIVES
==============================================================================

Pragmas are specified as comments at the top of the input .bas file (before
any non-comment code). They control special processing modes.

' #BANKING
  Enables banking mode. When enabled, the script generates multiple output
  files for different bank configurations:
    - <name>.pletter.bas       - Non-banked version (for CMake compatibility)
    - <name>.pletter_8k.bas    - 8KB bank configuration
    - <name>.pletter_8k.b0.bas - Bank 0 data for 8KB configuration
    - <name>.pletter_16k.bas   - 16KB bank configuration
    - <name>.pletter_16k.b0.bas - Bank 0 data for 16KB configuration

' #BANK0 label1, label2, ...
  Comma-separated list of labels that should be allocated to bank 0.
  Only valid when #BANKING is enabled. Labels not in this list will be
  automatically allocated to banks starting from the starting bank number.

' #BANK n
  Specifies the starting bank number for auto-allocation (default: 1).
  Only valid when #BANKING is enabled. Bank 0 is reserved for labels
  specified in #BANK0 and catalogue data.

' #CHUNKSIZE n
  Splits each data section into chunks of n bytes before compression.
  Each chunk is compressed separately and given a numbered suffix.
  For example, if bigData has 20000 bytes and CHUNKSIZE is 8192:
    - bigDataPletter0: (first 8192 bytes compressed)
    - bigDataPletter1: (next 8192 bytes compressed)
    - bigDataPletter2: (remaining bytes compressed)
  When chunking is enabled, a catalogue is automatically generated with
  VARPTR references to all chunks and chunk count information for each
  base label.
  If not specified, data sections are not chunked.

PRAGMA EXAMPLES:
  ' #BANKING
  ' #BANK0 menuGraphics, titleScreen
  ' #BANK 2

  ' #CHUNKSIZE 8192

==============================================================================
OUTPUT FORMAT
==============================================================================

The script generates CVBasic files containing compressed data as DATA BYTE
arrays. For each input label, it creates:

  - <LABEL>_SRC_SIZE constant with original uncompressed size
  - <label>Pletter: label marking start of compressed data
  - DATA BYTE lines with compressed bytes (8 bytes per line, hex format)
  - <label>PletterEnd: label marking end of compressed data

Chunking mode (with #CHUNKSIZE) additionally creates:
  - #<baseCamelName>ChunkCatalogue: array of VARPTR to all chunks
  - #<baseCamelName>ChunkCount: array of chunk counts per base label
  Where <baseCamelName> is the input filename converted to camelCase
  (e.g., gpu-supaplex.bin.bas -> gpuSupaplexBinChunkCatalogue)

Banking mode additionally creates catalogue arrays mapping label indices to
VARPTR addresses and bank numbers:
  - #<baseCamelName>Catalogue: array of VARPTR to all labels
  - <baseCamelName>Banks: array of bank numbers for each label

==============================================================================
"""

import re
import sys
import os
import subprocess
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

# Determine pletter executable path
# Priority: environment variable > command-line arg > default bundled exe
PLETTER_EXE = None
if 'PLETTER_EXE' in os.environ:
    PLETTER_EXE = Path(os.environ['PLETTER_EXE'])
else:
    scriptDir = Path(__file__).parent.resolve()
    PLETTER_EXE = scriptDir / 'cvbasic' / 'pletter.exe'

def _to_camel(name: str) -> str:
    """Convert a base filename to lowerCamelCase (gpu-supaplex.bin -> gpuSupaplexBin)."""
    parts = [p for p in re.split(r"[^A-Za-z0-9]+", name) if p]
    if not parts:
        return name
    head, *tail = parts
    return head.lower() + "".join(t.capitalize() for t in tail)


def _to_upper_snake(camel_case: str) -> str:
    """Convert camelCase to UPPER_SNAKE_CASE (gpuLoadLevel -> GPU_LOAD_LEVEL)."""
    return re.sub(r'(?<!^)(?=[A-Z])', '_', camel_case).upper()


def _format_pletter_label(label: str, suffix: str) -> str:
    """Format a label with Pletter suffix, handling chunked labels.

    Examples:
      bigData, 'Pletter' -> bigDataPletter
      bigData_0, 'Pletter' -> bigDataPletter0
      bigData_1, 'PletterEnd' -> bigDataPletterEnd1
    """
    # Check if label ends with _N where N is a digit
    match = re.match(r'^(.+)_(\d+)$', label)
    if match:
        base_label = match.group(1)
        chunk_num = match.group(2)
        return f"{base_label}{suffix}{chunk_num}"
    else:
        return f"{label}{suffix}"


def parseBankingDirectives(basPath):
    """Parses banking and processing directives from file header comments."""
    banking_enabled = False
    bank0_labels = []
    start_bank = 1  # Default starting bank
    chunk_size = None  # No chunking by default

    with open(basPath, 'r') as f:
        for line in f:
            stripped = line.strip()

            # Stop parsing after encountering non-comment, non-empty line
            if stripped and not stripped.startswith("'"):
                break

            if stripped.startswith("' #BANKING"):
                banking_enabled = True
            elif stripped.startswith("' #BANK0 "):
                # Extract comma-separated label list
                labels_str = stripped[len("' #BANK0 "):].strip()
                bank0_labels = [label.strip() for label in labels_str.split(',')]
            elif stripped.startswith("' #BANK "):
                # Extract starting bank number
                bank_str = stripped[len("' #BANK "):].strip()
                start_bank = int(bank_str)
            elif stripped.startswith("' #CHUNKSIZE "):
                # Extract chunk size in bytes
                chunk_str = stripped[len("' #CHUNKSIZE "):].strip()
                chunk_size = int(chunk_str)

    return banking_enabled, bank0_labels, start_bank, chunk_size


def extractLabelsAndData(basPath):
    """Parses a .bas file and extracts labeled DATA BYTE sequences."""
    currentLabel = None
    labelDataMap = {}
    dataBuffer = []

    with open(basPath, 'r') as f:
        for line in f:
            stripped = line.strip()

            if not stripped or stripped.startswith("'"):
                continue  # skip empty and comment lines

            # Strip comments (') but not apostrophes inside quoted strings
            codeOnly = ''
            in_quotes = False
            for ch in stripped:
                if ch == '"':
                    in_quotes = not in_quotes
                elif ch == "'" and not in_quotes:
                    break
                codeOnly += ch
            codeOnly = codeOnly.strip()
            if re.match(r'^[a-zA-Z_][\w]*\s*:$', codeOnly):

                if currentLabel and dataBuffer:
                    labelDataMap[currentLabel] = dataBuffer
                currentLabel = codeOnly[:-1]
                dataBuffer = []
                continue

            # remove comments and extract DATA BYTE declarations
            match = re.search(r'DATA\s+BYTE\s+(.*)', codeOnly, re.IGNORECASE)
            if match and currentLabel:
                # Split on commas, but not commas inside quoted strings
                rawValues = match.group(1)
                byteValues = []
                current = ''
                in_string = False
                for ch in rawValues:
                    if ch == '"':
                        in_string = not in_string
                        current += ch
                    elif ch == ',' and not in_string:
                        byteValues.append(current)
                        current = ''
                    else:
                        current += ch
                if current:
                    byteValues.append(current)
                for byte in byteValues:
                    byte = byte.strip()
                    if byte.startswith('"') and byte.endswith('"'):
                        # Handle string: strip quotes and convert each char to its ASCII value
                        for char in byte[1:-1]:
                            dataBuffer.append(ord(char))
                    elif byte.startswith('$'):
                        dataBuffer.append(int(byte[1:], 16))
                    elif byte.lower().startswith('0x'):
                        dataBuffer.append(int(byte, 16))
                    else:
                        dataBuffer.append(int(byte))
    if currentLabel and dataBuffer:
        labelDataMap[currentLabel] = dataBuffer

    return labelDataMap


def chunkLabelData(labelDataMap, chunk_size):
    """Splits each label's data into chunks of specified size.

    Returns a dict mapping label -> list of (chunk_index, chunk_data) tuples.
    For unchunked data, chunk_index is None.
    """
    if chunk_size is None:
        # Return data in the same format but with None chunk index
        return {label: [(None, data)] for label, data in labelDataMap.items()}

    chunked_map = {}

    for label, data in labelDataMap.items():
        data_size = len(data)

        if data_size <= chunk_size:
            # No chunking needed
            chunked_map[label] = [(None, data)]
        else:
            # Split into chunks
            chunks = []
            num_chunks = (data_size + chunk_size - 1) // chunk_size  # Ceiling division
            for i in range(num_chunks):
                start_idx = i * chunk_size
                end_idx = min(start_idx + chunk_size, data_size)
                chunks.append((i, data[start_idx:end_idx]))
            chunked_map[label] = chunks

    return chunked_map

def compressDataViaPletter(data, tempDir, label):
    """writes data to disk, compresses it via pletter.exe, and reads back output bytes."""
    binPath = tempDir / f"{label}.bin"
    pletterPath = tempDir / f"{label}.pletter.bin"

    with open(binPath, 'wb') as f:
        f.write(bytearray(data))

    result = subprocess.run([str(PLETTER_EXE), str(binPath), str(pletterPath)],
                            capture_output=True, text=True)

    if result.returncode != 0:
        raise RuntimeError(f"[X] Pletter compression failed for {label}:\n{result.stderr}")

    with open(pletterPath, 'rb') as f:
        compressed_data = list(f.read())

    # Ensure even number of bytes by padding with $00 if needed
    if len(compressed_data) % 2 == 1:
        compressed_data.append(0x00)

    return compressed_data


def allocateDataToBanks(compressedBlocks, bank0_labels, bank_size, start_bank=1):
    """Allocates compressed data blocks to banks dynamically.

    Returns: dict mapping bank_num -> list of (label, compressed_data) tuples
    """
    banks = {0: []}  # Bank 0 always exists
    current_bank = start_bank
    current_bank_size = 0
    banks[current_bank] = []

    # First, allocate bank0 labels to bank 0
    for label in bank0_labels:
        if label in compressedBlocks:
            banks[0].append((label, compressedBlocks[label]))

    # Then allocate remaining labels to banks starting from start_bank
    for label, data in compressedBlocks.items():
        if label in bank0_labels:
            continue  # Already in bank 0

        data_size = len(data)

        # Check if this fits in current bank
        if current_bank_size + data_size > bank_size:
            # Move to next bank
            current_bank += 1
            current_bank_size = 0
            banks[current_bank] = []

        banks[current_bank].append((label, data))
        current_bank_size += data_size

    return banks


def writeFinalBas(inputBas, basOutputPath, compressedBlocks, sourceSizes, has_chunks=False):
    """generates the output .pletter.bas with compressed data blocks."""

    totalSourceBytes = 0
    totalCompressedBytes = 0
    # Ensure basOutputPath is a Path object and extract just the filename for display
    basOutputPath = Path(basOutputPath)
    basOutputFile = basOutputPath.name
    baseFileName = Path(inputBas).stem
    baseCamelName = _to_camel(baseFileName)
    generated_at = datetime.now().isoformat(timespec="seconds")

    with open(basOutputPath, 'w') as f:
        f.write("' ====================================================\n")
        f.write("' This file was generated using cvpletter.py\n")
        f.write("' \n")
        f.write("' Copyright (c) 2026 Troy Schrapel (visrealm)\n")
        f.write("' \n")
        f.write(f"' generated: {generated_at}\n")
        f.write(f"' source: {inputBas}\n")
        f.write(f"' cmd:    python cvpletter.py {inputBas}\n")
        f.write(f"' output: {basOutputFile}\n")
        f.write("' \n")
        f.write("' ====================================================\n")
        f.write("' WARNING! Do NOT edit this file. Edit source file\n")
        f.write("' ====================================================\n\n")

        # Write source size constants
        for label, compressed in compressedBlocks.items():
            inSize = sourceSizes[label]
            # Convert camelCase to UPPER_SNAKE_CASE
            constantName = _to_upper_snake(label)
            f.write(f"  CONST {constantName}_SRC_SIZE = {inSize}\n")
        f.write("\n")

        # Write catalogue if data is chunked
        if has_chunks:
            all_labels = list(compressedBlocks.keys())

            f.write(f"  #{baseCamelName}ChunkCatalogue:\n")
            for label in all_labels:
                pletter_label = _format_pletter_label(label, "Pletter")
                f.write(f"    DATA VARPTR {pletter_label}(0)\n")
            f.write(f"  {baseCamelName}ChunkCatalogueEnd:\n\n")

            # Write chunk count information
            # Group chunks by base label
            base_label_chunks = {}
            for label in all_labels:
                match = re.match(r'^(.+)_\d+$', label)
                if match:
                    base = match.group(1)
                    if base not in base_label_chunks:
                        base_label_chunks[base] = 0
                    base_label_chunks[base] += 1
                else:
                    # Not a chunked label
                    if label not in base_label_chunks:
                        base_label_chunks[label] = 1

            f.write(f"  #{baseCamelName}ChunkCount:\n")
            for base_label in base_label_chunks.keys():
                count = base_label_chunks[base_label]
                f.write(f"    DATA {count} ' {base_label}\n")
            f.write(f"  {baseCamelName}ChunkCountEnd:\n\n")

        for label, compressed in compressedBlocks.items():
            inSize = sourceSizes[label]
            outSize = len(compressed)
            totalSourceBytes += inSize
            totalCompressedBytes += outSize

            start_label = _format_pletter_label(label, "Pletter")
            end_label = _format_pletter_label(label, "PletterEnd")

            f.write(f"  {start_label}: ' source: {inSize} bytes. compressed: {outSize} bytes\n")
            for i in range(0, outSize, 8):
                group = compressed[i:i+8]
                line = ', '.join(f"${b:02x}" for b in group)
                f.write(f"    DATA BYTE {line}\n")
            f.write(f"  {end_label}:\n")
            f.write("\n")

            print(f"  {start_label + ':':<25} - in: {str(inSize) + 'B':>6} - out: {str(outSize) + 'B':>6} - saved: {str(inSize - outSize)+'B':>6}")

    print(f"{basOutputFile:<27} - in: {str(totalSourceBytes) + 'B':>6} - out: {str(totalCompressedBytes) + 'B':>6} - saved: {str(totalSourceBytes - totalCompressedBytes)+ 'B':>6}\n")


def _writeBankFile(path, header_lines, bank_num, bank_blocks, sourceSizes, emit_bank_directive):
    """Writes a single per-bank data file. Returns (source_bytes, compressed_bytes)."""
    totalSourceBytes = 0
    totalCompressedBytes = 0

    with open(path, 'w') as f:
        for line in header_lines:
            f.write(line)

        if emit_bank_directive:
            f.write(f"BANK {bank_num}\n\n")

        for label, compressed in bank_blocks:
            inSize = sourceSizes[label]
            outSize = len(compressed)
            totalSourceBytes += inSize
            totalCompressedBytes += outSize

            start_label = _format_pletter_label(label, "Pletter")
            end_label = _format_pletter_label(label, "PletterEnd")

            f.write(f"  {start_label}: ' source: {inSize} bytes. compressed: {outSize} bytes\n")
            for i in range(0, outSize, 8):
                group = compressed[i:i+8]
                line = ', '.join(f"${b:02x}" for b in group)
                f.write(f"    DATA BYTE {line}\n")
            f.write(f"  {end_label}:\n")
            f.write("\n")

            print(f"  Bank {bank_num}: {start_label + ':':<20} - in: {str(inSize) + 'B':>6} - out: {str(outSize) + 'B':>6} - saved: {str(inSize - outSize)+'B':>6}")

    return totalSourceBytes, totalCompressedBytes


def writeBankedBas(inputBas, basOutputPath, compressedBlocks, sourceSizes, bank0_labels, bank_size, bank_size_name, start_bank=1):
    """Generates output .pletter.bas with banking support.

    Emits one file per bank (.b0.bas, .b<N>.bas, ...) plus a wrapper
    (the basOutputPath itself) that INCLUDEs every per-bank file in order.
    Bank 0's file contains the label catalogue, Banks table, and any bank-0
    payload; subsequent banks contain their labels preceded by BANK <n>.
    """

    banks = allocateDataToBanks(compressedBlocks, bank0_labels, bank_size, start_bank)

    basOutputPath = Path(basOutputPath)
    basOutputFile = basOutputPath.name
    baseFileName = inputBas.stem
    baseCamelName = _to_camel(baseFileName)
    generated_at = datetime.now().isoformat(timespec="seconds")

    # Derive variant suffix (e.g. "_8k" from "foo.pletter_8k.bas"); used in per-bank filenames
    stem_parts = basOutputPath.stem.split('.')
    if len(stem_parts) > 1 and stem_parts[-1].startswith('pletter'):
        variant = stem_parts[-1][7:]
    else:
        variant = ""

    # Build label catalogue and bank mapping (in emission order)
    all_labels = []
    label_to_bank = {}
    for bank_num in sorted(banks.keys()):
        for label, data in banks[bank_num]:
            all_labels.append(label)
            label_to_bank[label] = bank_num

    def bank_path(bank_num):
        return basOutputPath.parent / f"{baseFileName}.pletter{variant}.b{bank_num}.bas"

    # Header lines reused for every per-bank file
    def make_header(bank_num, path):
        return [
            "' ====================================================\n",
            "' This file was generated using cvpletter.py\n",
            f"' Bank {bank_num} data file\n",
            "' \n",
            "' Copyright (c) 2026 Troy Schrapel (visrealm)\n",
            "' \n",
            f"' generated: {generated_at}\n",
            f"' source: {inputBas}\n",
            f"' bank size: {bank_size_name}\n",
            f"' cmd:    python cvpletter.py {inputBas}\n",
            f"' output: {path.name}\n",
            "' \n",
            "' ====================================================\n",
            "' WARNING! Do NOT edit this file. Edit source file\n",
            "' ====================================================\n\n",
        ]

    # --- Bank 0 file: catalogue + Banks table + bank-0 payload ---
    bank0_path = bank_path(0)
    with open(bank0_path, 'w') as f:
        for line in make_header(0, bank0_path):
            f.write(line)

        for label in all_labels:
            inSize = sourceSizes[label]
            constantName = _to_upper_snake(label)
            f.write(f"  CONST {constantName}_SRC_SIZE = {inSize}\n")
        f.write("\n")

        f.write(f"  #{baseCamelName}Catalogue:\n")
        for label in all_labels:
            pletter_label = _format_pletter_label(label, "Pletter")
            f.write(f"    DATA VARPTR {pletter_label}(0)\n")
        f.write(f"  {baseCamelName}CatalogueEnd:\n\n")

        f.write(f"  {baseCamelName}Banks:\n")
        for label in all_labels:
            f.write(f"    DATA BYTE {label_to_bank[label]} ' {label}\n")
        f.write(f"  {baseCamelName}BanksEnd:\n\n")

    totalSourceBytes = 0
    totalCompressedBytes = 0

    if 0 in banks and banks[0]:
        with open(bank0_path, 'a') as f:
            for label, compressed in banks[0]:
                inSize = sourceSizes[label]
                outSize = len(compressed)
                totalSourceBytes += inSize
                totalCompressedBytes += outSize

                start_label = _format_pletter_label(label, "Pletter")
                end_label = _format_pletter_label(label, "PletterEnd")

                f.write(f"  {start_label}: ' source: {inSize} bytes. compressed: {outSize} bytes\n")
                for i in range(0, outSize, 8):
                    group = compressed[i:i+8]
                    line = ', '.join(f"${b:02x}" for b in group)
                    f.write(f"    DATA BYTE {line}\n")
                f.write(f"  {end_label}:\n")
                f.write("\n")

                print(f"  Bank 0: {start_label + ':':<20} - in: {str(inSize) + 'B':>6} - out: {str(outSize) + 'B':>6} - saved: {str(inSize - outSize)+'B':>6}")

    print(f"  -> {bank0_path.name}")

    # --- Per-bank files for banks >= start_bank ---
    # Files do NOT emit their own `BANK N` directive; the wrapper emits it
    # before the include. This lets non-banked targets include the same
    # per-bank files (from a different wrapper) without a `BANK` directive.
    non_zero_banks = [b for b in sorted(banks.keys()) if b != 0]
    for bank_num in non_zero_banks:
        path = bank_path(bank_num)
        src, comp = _writeBankFile(path, make_header(bank_num, path), bank_num, banks[bank_num], sourceSizes, emit_bank_directive=False)
        totalSourceBytes += src
        totalCompressedBytes += comp
        print(f"  -> {path.name}")

    # The caller is responsible for including the per-bank files in the
    # right place (bank 0 in bank-0 position, later banks in their positions)
    # and emitting the BANK directive for each. The wrapper file is written
    # purely as a manifest so downstream tools / CMake can treat it as the
    # primary output.
    with open(basOutputPath, 'w') as f:
        for line in make_header("manifest", basOutputPath):
            f.write(line)
        f.write(f"' Per-bank files produced for this variant:\n")
        f.write(f"'   {bank0_path.name}   (bank 0: catalogue + bank-0 payload)\n")
        for bank_num in non_zero_banks:
            f.write(f"'   {bank_path(bank_num).name}   (bank {bank_num})\n")

    print(f"{basOutputFile:<27} - in: {str(totalSourceBytes) + 'B':>6} - out: {str(totalCompressedBytes) + 'B':>6} - saved: {str(totalSourceBytes - totalCompressedBytes)+ 'B':>6}")
    print(f"Total banks used: {len(banks)}\n")


def main():
    # Usage: python cvpletter.py <input.bas> [output.bas] [-o output_dir]
    args = [a for a in sys.argv[1:] if a]

    if len(args) < 1 or len(args) > 3:
        print("Usage: python cvpletter.py <input.bas> [output.bas] [-o output_dir]")
        sys.exit(1)

    inputBas = Path(args[0])
    if not inputBas.exists():
        print(f"[X] File not found: {inputBas}")
        sys.exit(1)

    if not PLETTER_EXE.exists():
        print(f"[X] Missing pletter.exe at: {PLETTER_EXE}")
        sys.exit(1)

    # Parse arguments for output path or output directory
    outputBasPath = None
    outputDir = None

    # Check for -o flag
    if len(args) >= 2:
        if args[1] == '-o' and len(args) == 3:
            outputDir = Path(args[2])
        elif len(args) == 2 and args[1] != '-o':
            outputBasPath = Path(args[1])
        elif len(args) == 3 and args[1] != '-o':
            outputBasPath = Path(args[1])

    print(f"Processing {inputBas}...")

    # Check for banking and processing directives
    banking_enabled, bank0_labels_orig, start_bank, chunk_size = parseBankingDirectives(inputBas)

    labelsData = extractLabelsAndData(inputBas)

    # Apply chunking - returns dict of label -> list of (chunk_index, data)
    if chunk_size:
        print(f"Chunking enabled: {chunk_size} bytes per chunk")

    chunkedData = chunkLabelData(labelsData, chunk_size)

    # Expand bank0_labels to include all chunks from those labels
    bank0_labels = []
    for orig_label in bank0_labels_orig:
        if orig_label in chunkedData:
            for chunk_idx, _ in chunkedData[orig_label]:
                if chunk_idx is None:
                    bank0_labels.append(orig_label)
                else:
                    bank0_labels.append(f"{orig_label}_{chunk_idx}")

    # Flatten chunked data into individual compressed blocks
    compressedBlocks = {}
    sourceSizes = {}
    has_chunks = False

    with TemporaryDirectory() as tmp:
        tempDir = Path(tmp)
        for base_label, chunks in chunkedData.items():
            for chunk_idx, data in chunks:
                # Generate unique label for this chunk
                if chunk_idx is None:
                    label = base_label
                    temp_label = base_label
                else:
                    label = f"{base_label}_{chunk_idx}"
                    temp_label = f"{base_label}_{chunk_idx}"
                    has_chunks = True

                compressedBlocks[label] = compressDataViaPletter(data, tempDir, temp_label)
                sourceSizes[label] = len(data)

    if banking_enabled:
        print(f"\n*** Banking mode enabled ***")
        print(f"Starting bank: {start_bank}")
        print(f"Bank 0 labels: {', '.join(bank0_labels)}\n")

        # Determine base output path
        if outputBasPath is None:
            if outputDir:
                outputBasPath = outputDir / f"{inputBas.stem}.pletter.bas"
            else:
                outputBasPath = inputBas.parent / f"{inputBas.stem}.pletter.bas"

        outputBasPath.parent.mkdir(parents=True, exist_ok=True)

        # Generate regular non-banked version for CMake compatibility
        print(f"Generating non-banked version: {outputBasPath.name}")
        writeFinalBas(inputBas, outputBasPath, compressedBlocks, sourceSizes, has_chunks)

        # Generate 8KB version
        output8k = outputBasPath.parent / f"{outputBasPath.stem}_8k.bas"
        print(f"Generating 8KB bank version: {output8k.name}")
        writeBankedBas(inputBas, output8k, compressedBlocks, sourceSizes, bank0_labels, 8192 - 48, "8KB", start_bank)

        # Generate 16KB version
        output16k = outputBasPath.parent / f"{outputBasPath.stem}_16k.bas"
        print(f"Generating 16KB bank version: {output16k.name}")
        writeBankedBas(inputBas, output16k, compressedBlocks, sourceSizes, bank0_labels, 16384 - 48, "16KB", start_bank)

        # Generate 32KB version (flat/non-banked targets consume the b0 file directly)
        output32k = outputBasPath.parent / f"{outputBasPath.stem}_32k.bas"
        print(f"Generating 32KB bank version: {output32k.name}")
        writeBankedBas(inputBas, output32k, compressedBlocks, sourceSizes, bank0_labels, 32768 - 48, "32KB", start_bank)
    else:
        # Non-banked mode - original behavior
        # Determine final output path
        if outputBasPath is None:
            if outputDir:
                outputBasPath = outputDir / f"{inputBas.stem}.pletter.bas"
            else:
                outputBasPath = inputBas.parent / f"{inputBas.stem}.pletter.bas"

        # Ensure output directory exists
        outputBasPath.parent.mkdir(parents=True, exist_ok=True)

        writeFinalBas(inputBas, outputBasPath, compressedBlocks, sourceSizes, has_chunks)

if __name__ == '__main__':
    main()
