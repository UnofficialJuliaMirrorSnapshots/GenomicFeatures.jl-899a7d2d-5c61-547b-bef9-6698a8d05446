# BigWig Reader
# =============

struct Reader <: BioCore.IO.AbstractReader
    stream::IO
    header::BBI.Header
    zooms::Vector{BBI.Zoom}
    summary::BBI.Summary
    # chrom name => (ID, length)
    chroms::Dict{String,Tuple{UInt32,Int}}
    # ID => chrom name
    chrom_names::Dict{UInt32,String}
    # data index
    index::BBI.RTree
end

function Base.eltype(::Type{Reader})
    return Record
end

function BioCore.IO.stream(reader::Reader)
    return reader.stream
end

"""
    BigWig.Reader(input::IO)

Create a reader for bigWig file format.

Note that `input` must be seekable.
"""
function Reader(input::IO)
    # read header
    header = read(input, BBI.Header)
    if header.magic != BBI.WIG_MAGIC
        error("invalid bigWig magic")
    elseif header.version < 3
        error("not a supported version of bigWig")
    end
    # read zoom objects
    zoom_headers = Vector{BBI.ZoomHeader}(undef, header.zoom_levels)
    read!(input, zoom_headers)
    zooms = [BBI.Zoom(input, h, header.uncompress_buf_size) for h in zoom_headers]
    sort!(zooms, by=z->z.header.reduction_level)
    # read summary, B tree, and R tree
    seek(input, header.total_summary_offset)
    summary = read(input, BBI.Summary)
    chromindex = BBI.BTree(input, header.chromosome_tree_offset)
    chroms = Dict(name => (id, Int(len)) for (name, id, len) in BBI.chromlist(chromindex))
    chrom_names = Dict(id => name for (name, (id, _)) in chroms)
    index = BBI.RTree(input, header.full_index_offset)
    return Reader(input, header, zooms, summary, chroms, chrom_names, index)
end

"""
    chromlist(reader::BigWig.Reader)::Vector{Tuple{String,Int}}

Get the `(name, length)` pairs of chromosomes/contigs.
"""
function chromlist(reader::Reader)::Vector{Tuple{String,Int}}
    return sort!([(name, Int(len)) for (name, (id, len)) in reader.chroms], by=x->x[1])
end

"""
    values(reader::BigWig.Reader, interval::Interval)::Vector{Float32}

Get a vector of values within `interval` from `reader`.

This function fills missing values with `NaN32`.
"""
function values(reader::Reader, interval::Interval)
    return values(reader, interval.seqname, interval.first:interval.last)
end

"""
    values(reader::BigWig.Reader, chrom::AbstractString, range::UnitRange)::Vector{Float32}

Get a vector of values within `range` of `chrom` from `reader`.

This function fills missing values with `NaN32`.
"""
function values(reader::Reader, chrom::AbstractString, range::UnitRange)::Vector{Float32}
    values = Vector{Float32}(undef, length(range))
    if isempty(range)
        return values
    end
    fill!(values, NaN32)
    offset = first(range) - 1
    for record in GenomicFeatures.eachoverlap(reader, Interval(chrom, first(range), last(range)))
        rstart = clamp(record.chromstart+1-offset, 1, lastindex(values))
        rend = clamp(record.chromend-offset, 1, lastindex(values))
        values[rstart:rend] .= record.value
    end
    return values
end


# Record
# ------

mutable struct Record
    chromstart::UInt32
    chromend::UInt32
    value::Float32
    header::SectionHeader
    reader::Reader

    function Record(chromstart, chromend, value)
        return new(chromstart, chromend, value)
    end
end


# Iterator
# --------

mutable struct IteratorState
    stream::BufferedStreams.BufferedInputStream
    done::Bool
    header::SectionHeader
    record::Record
    n_sections::UInt64
    current_section::UInt64
    n_records::UInt16
    current_record::UInt16
end

function Base.iterate(reader::Reader)
    seek(reader.stream, reader.header.full_data_offset)
    # this is defined as UInt32 in the spces but actually UInt64
    section_count = read(reader.stream, UInt64)
    # dummy header
    header = SectionHeader(0, 0, 0, 0, 0, 0, 0, 0)
    state = IteratorState(Libz.ZlibInflateInputStream(reader.stream), false, header, Record(), section_count, 0, 0, 0)
    return iterate(reader, state)
end

function Base.iterate(reader::Reader, state)
    advance!(reader, state)
    if state.done
        return nothing
    else
        return copy(state.record), state
    end
end

function advance!(reader::Reader, state::IteratorState)
    # find a section that has at least one record
    while state.current_section < state.n_sections && state.current_record == state.n_records
        state.header = read(state.stream, SectionHeader)
        state.current_section += 1
        state.n_records = state.header.itemcount
        state.current_record = 0
    end
    if state.current_record == state.n_records
        state.done = true
        return state
    end

    # read a new record
    _read!(reader, state, state.record)
    return state
end

function _read!(reader::Reader, state, record::Record)
    @assert !state.done
    header = state.header
    if isbedgraph(header.datatype)
        chromstart = read(state.stream, UInt32)
        chromend   = read(state.stream, UInt32)
    elseif isvarstep(header.datatype)
        chromstart = read(state.stream, UInt32)
        chromend   = chromstart + header.itemspan
    elseif isfixedstep(header.datatype)
        chromstart = state.current_record == 0 ? header.chromstart : state.record.chromstart + header.itemstep
        chromend   = chromstart + header.itemspan
    else
        throw(ArgumentError("invalid data type"))
    end
    value = read(state.stream, Float32)
    record.chromstart = chromstart
    record.chromend = chromend
    record.value = value
    record.header = header
    record.reader = reader
    state.current_record += 1
    return record
end
