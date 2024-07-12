# SPDX-License-Identifier: MIT

########################################################
# Node utilities extensions and JuliaSyntax extensions #
########################################################

# JuliaSyntax.jl overloads == for this but seems easier to just define a new function
function nodes_equal(n1::Node, n2::Node)
    # return head(n1) == head(n2) && span(n1) == span(n2) && # n1.tags == n2.tags &&
    #     all(((x, y),) -> nodes_equal(x, y), zip(n1.kids, n2.kids))
    if !(head(n1) == head(n2) && span(n1) == span(n2))
        return false
    end
    if length(n1.kids) != length(n2.kids)
        return false
    end
    for i in 1:length(n1.kids)
        nodes_equal(n1.kids[i], n2.kids[i]) || return false
    end
    return true
end

# See JuliaSyntax/src/parse_stream.jl
function stringify_flags(node::Node)
    io = IOBuffer()
    if JuliaSyntax.has_flags(node, JuliaSyntax.TRIVIA_FLAG)
        write(io, "trivia,")
    end
    if JuliaSyntax.is_operator(kind(node))
        if JuliaSyntax.has_flags(node, JuliaSyntax.DOTOP_FLAG)
            write(io, "dotted,")
        end
        if JuliaSyntax.has_flags(node, JuliaSyntax.SUFFIXED_FLAG)
            write(io, "suffixed,")
        end
    end
    if kind(node) in KSet"call dotcall"
        if JuliaSyntax.has_flags(node, JuliaSyntax.PREFIX_CALL_FLAG)
            write(io, "prefix-call,")
        end
        if JuliaSyntax.has_flags(node, JuliaSyntax.INFIX_FLAG)
            write(io, "infix-op,")
        end
        if JuliaSyntax.has_flags(node, JuliaSyntax.PREFIX_OP_FLAG)
            write(io, "prefix-op,")
        end
        if JuliaSyntax.has_flags(node, JuliaSyntax.POSTFIX_OP_FLAG)
            write(io, "postfix-op,")
        end
    end
    if kind(node) in KSet"string cmdstring" &&
            JuliaSyntax.has_flags(node, JuliaSyntax.TRIPLE_STRING_FLAG)
        write(io, "triple,")
    end
    if kind(node) in KSet"string cmdstring Identifier" &&
            JuliaSyntax.has_flags(node, JuliaSyntax.RAW_STRING_FLAG)
        write(io, "raw,")
    end
    if kind(node) in KSet"tuple block macrocall" &&
            JuliaSyntax.has_flags(node, JuliaSyntax.PARENS_FLAG)
        write(io, "parens,")
    end
    if kind(node) === K"quote" && JuliaSyntax.has_flags(node, JuliaSyntax.COLON_QUOTE)
        write(io, "colon,")
    end
    if kind(node) === K"toplevel" && JuliaSyntax.has_flags(node, JuliaSyntax.TOPLEVEL_SEMICOLONS_FLAG)
        write(io, "semicolons,")
    end
    if kind(node) === K"struct" && JuliaSyntax.has_flags(node, JuliaSyntax.MUTABLE_FLAG)
        write(io, "mutable,")
    end
    if kind(node) === K"module" && JuliaSyntax.has_flags(node, JuliaSyntax.BARE_MODULE_FLAG)
        write(io, "baremodule,")
    end
    truncate(io, max(0, position(io) - 1)) # Remove trailing comma
    return String(take!(io))
end


# Node tags #

# This node is responsible for incrementing the indentation level
const TAG_INDENT = TagType(1) << 0
# This node is responsible for decrementing the indentation level
const TAG_DEDENT = TagType(1) << 1
# This (NewlineWs) node is the last one before a TAG_DEDENT
const TAG_PRE_DEDENT = TagType(1) << 2
# This (NewlineWs) node is a line continuation
const TAG_LINE_CONT = UInt32(1) << 31
# Parameters that should have a trailing comma after last item
const TAG_TRAILING_COMMA = TagType(1) << 4

function add_tag(node::Node, tag::TagType)
    if kind(node) !== K"parameters"
        @assert is_leaf(node)
    end
    return Node(head(node), span(node), node.kids, node.tags | tag)
end

# Tags all leading NewlineWs nodes as continuation nodes. Note that comments are skipped
# over so that cases like `\n#comment\ncode` works as expected.
function continue_newlines(node::Node; leading::Bool = true, trailing::Bool = true)
    if is_leaf(node)
        if kind(node) === K"NewlineWs" && !has_tag(node, TAG_LINE_CONT)
            return add_tag(node, TAG_LINE_CONT)
        else
            return nothing
        end
    end
    kids = verified_kids(node)
    if length(kids) == 1
        return nothing
    end
    any_kid_changed = false
    if leading
        idx = firstindex(kids) - 1
        while true
            # Skip over whitespace + comments which can mask the newlines
            idx = findnext(x -> !(kind(x) in KSet"Whitespace Comment"), kids, idx + 1)
            if idx === nothing
                # No matching kid found
                break
            elseif kind(kids[idx]) === K"NewlineWs"
                # Kid is a NewlineWs node, tag and keep looking
                kid′ = continue_newlines(kids[idx]; leading = leading, trailing = trailing)
                if kid′ !== nothing
                    kids[idx] = kid′
                    any_kid_changed = false
                end
            else
                # This kid is not Whitespace, Comment or NewlineWs.
                # Recurse but break out of the loop
                kid′ = continue_newlines(kids[idx]; leading = leading, trailing = trailing)
                if kid′ !== nothing
                    kids[idx] = kid′
                    any_kid_changed = false
                end
                break
            end
        end
    end
    if trailing
        idx = lastindex(kids) + 1
        while true
            # Skip over whitespace + comments which can mask the newlines
            idx = findprev(x -> !(kind(x) in KSet"Whitespace Comment"), kids, idx - 1)
            if idx === nothing
                # No matching kid found
                break
            elseif kind(kids[idx]) === K"NewlineWs"
                # Kid is a NewlineWs node, tag and keep looking
                kid′ = continue_newlines(kids[idx]; leading = leading, trailing = trailing)
                if kid′ !== nothing
                    kids[idx] = kid′
                    any_kid_changed = false
                end
            else
                # This kid is not Whitespace, Comment or NewlineWs.
                # Recurse but break out of the loop
                kid′ = continue_newlines(kids[idx]; leading = leading, trailing = trailing)
                if kid′ !== nothing
                    kids[idx] = kid′
                    any_kid_changed = false
                end
                break
            end
        end
    end
    return any_kid_changed ? node : nothing
end

function has_tag(node::Node, tag::TagType)
    return node.tags & tag != 0
end

function stringify_tags(node::Node)
    io = IOBuffer()
    if has_tag(node, TAG_INDENT)
        write(io, "indent,")
    end
    if has_tag(node, TAG_DEDENT)
        write(io, "dedent,")
    end
    if has_tag(node, TAG_PRE_DEDENT)
        write(io, "pre-dedent,")
    end
    if has_tag(node, TAG_LINE_CONT)
        write(io, "line-cont.,")
    end
    truncate(io, max(0, position(io) - 1)) # Remove trailing comma
    return String(take!(io))
end

# Create a new node with the same head but new kids
function make_node(node::Node, kids′::Vector{Node}, tags = node.tags)
    span′ = mapreduce(span, +, kids′; init = 0)
    return Node(head(node), span′, kids′, tags)
end

function first_leaf(node::Node)
    if is_leaf(node)
        return node
    else
        return first_leaf(first(verified_kids(node)))
    end
end

function second_leaf(node::Node)
    if is_leaf(node)
        return nothing
    else
        kids = verified_kids(node)
        if length(kids) == 0
            return nothing
        elseif !is_leaf(kids[1])
            return second_leaf(kids[1])
        elseif length(kids) > 1
            @assert is_leaf(kids[1])
            return first_leaf(kids[2])
        else
            @assert false
        end
    end
end

# Return number of non-whitespace kids, basically the length the equivalent
# (expr::Expr).args
function meta_nargs(node::Node)
    return is_leaf(node) ? 0 : count(!JuliaSyntax.is_whitespace, verified_kids(node))
end

# Replace the first leaf
# TODO: Append the replacement bytes inside this utility function?
function replace_first_leaf(node::Node, kid′::Union{Node, NullNode})
    if is_leaf(node)
        return kid′
    else
        kids′ = copy(verified_kids(node))
        kid′′ = replace_first_leaf(kids′[1], kid′)
        if kid′′ === nullnode
            popfirst!(kids′)
        else
            kids′[1] = kid′′
        end
        # kids′[1] = replace_first_leaf(kids′[1], kid′)
        @assert length(kids′) > 0
        return make_node(node, kids′)
    end
end

function replace_last_leaf(node::Node, kid′::Union{Node, NullNode})
    if is_leaf(node)
        return kid′
    else
        kids′ = copy(verified_kids(node))
        kid′′ = replace_last_leaf(kids′[end], kid′)
        if kid′′ === nullnode
            pop!(kids′)
        else
            kids′[end] = kid′′
        end
        @assert length(kids′) > 0
        return make_node(node, kids′)
    end
end

function last_leaf(node::Node)
    if is_leaf(node)
        return node
    else
        return last_leaf(last(verified_kids(node)))
    end
end

function has_newline_after_non_whitespace(node::Node)
    if is_leaf(node)
        @assert kind(node) !== K"NewlineWs"
        return false
    else
        kids = verified_kids(node)
        idx = findlast(!JuliaSyntax.is_whitespace, kids)
        if idx === nothing
            @assert false
            # Everything is whitespace...
            return any(x -> kind(x) === K"NewlineWs", kids)
        end
        return any(x -> kind(x) === K"NewlineWs", kids[(idx + 1):end]) ||
            has_newline_after_non_whitespace(kids[idx])
        # if idx === nothing
        #     # All is whitespace, check if any of the kids is a newline
        #     return any(x -> kind(x) === K"NewlineWs", kids)
        # end
    end
end

function is_assignment(node::Node)
    return JuliaSyntax.is_prec_assignment(node)
    # return !is_leaf(node) && JuliaSyntax.is_prec_assignment(node)
end

function unwrap_to_call_or_tuple(x)
    is_leaf(x) && return nothing
    @assert !is_leaf(x)
    if kind(x) in KSet"call tuple"
        return x
    end
    xkids = verified_kids(x)
    xi = findfirst(x -> !JuliaSyntax.is_whitespace(x), xkids)::Int
    return unwrap_to_call_or_tuple(xkids[xi])
end

function is_longform_anon_function(node::Node)
    is_leaf(node) && return false
    kind(node) === K"function" || return false
    kids = verified_kids(node)
    kw = findfirst(x -> kind(x) === K"function", kids)
    @assert kw !== nothing
    sig = findnext(x -> !JuliaSyntax.is_whitespace(x), kids, kw + 1)::Int
    sigkid = kids[sig]
    maybe_tuple = unwrap_to_call_or_tuple(sigkid)
    if maybe_tuple === nothing
        return false
    else
        return kind(maybe_tuple) === K"tuple"
    end
end

# Just like `JuliaSyntax.is_infix_op_call`, but also check that the node is K"call" or
# K"dotcall"
function is_infix_op_call(node::Node)
    return kind(node) in KSet"call dotcall" && JuliaSyntax.is_infix_op_call(node)
end

# Extract the operator of an infix op call node
function infix_op_call_op(node::Node)
    @assert is_infix_op_call(node) || kind(node) === K"||"
    kids = verified_kids(node)
    first_operand_index = findfirst(!JuliaSyntax.is_whitespace, kids)
    op_index = findnext(JuliaSyntax.is_operator, kids, first_operand_index + 1)
    return kids[op_index]
end

# Comparison leaf or a dotted comparison leaf (.<)
function is_comparison_leaf(node::Node)
    if is_leaf(node) && JuliaSyntax.is_prec_comparison(node)
        return true
    elseif !is_leaf(node) && kind(node) === K"." &&
            meta_nargs(node) == 2 && is_comparison_leaf(verified_kids(node)[2])
        return true
    else
        return false
    end
end

function is_operator_leaf(node::Node)
    return is_leaf(node) && JuliaSyntax.is_operator(node)
end

function first_non_whitespace_kid(node::Node)
    @assert !is_leaf(node)
    kids = verified_kids(node)
    idx = findfirst(!JuliaSyntax.is_whitespace, kids)::Int
    return kids[idx]
end

function is_begin_block(node::Node)
    return kind(node) === K"block" && length(verified_kids(node)) > 0 &&
        kind(verified_kids(node)[1]) === K"begin"
end

function is_paren_block(node::Node)
    return kind(node) === K"block" && JuliaSyntax.has_flags(node, JuliaSyntax.PARENS_FLAG)
end

function first_leaf_predicate(node::Node, pred::F) where {F}
    if is_leaf(node)
        return pred(node) ? node : nothing
    else
        kids = verified_kids(node)
        for k in kids
            r = first_leaf_predicate(k, pred)
            if r !== nothing
                return r
            end
        end
        return nothing
    end
end

function last_leaf_predicate(node::Node, pred::F) where {F}
    if is_leaf(node)
        return pred(node) ? node : nothing
    else
        kids = verified_kids(node)
        for k in Iterators.reverse(kids)
            r = first_leaf_predicate(k, pred)
            if r !== nothing
                return r
            end
        end
        return nothing
    end
end

function contains_outer_newline(kids::Vector{Node}, oidx::Int, cidx::Int; recurse = true)
    pred = x -> kind(x) === K"NewlineWs" || !JuliaSyntax.is_whitespace(x)
    for i in (oidx + 1):(cidx - 1)
        kid = kids[i]
        r = first_leaf_predicate(kid, pred)
        if r !== nothing && kind(r) === K"NewlineWs"
            return true
        end
        r = last_leaf_predicate(kid, pred)
        if r !== nothing && kind(r) === K"NewlineWs"
            return true
        end
        if kind(kid) === K"parameters"
            grandkids = verified_kids(kid)
            semiidx = findfirst(x -> kind(x) === K";", grandkids)::Int
            r = contains_outer_newline(verified_kids(kid), semiidx, length(grandkids) + 1)
            if r === true # r can be nothing so `=== true` is intentional
                return true
            end
        end
    end
    return false
end

function any_leaf(pred::F, node::Node) where {F}
    if is_leaf(node)
        return pred(node)::Bool
    else
        kids = verified_kids(node)
        for k in kids
            any_leaf(pred, k) && return true
        end
        return false
    end
end

##########################
# Utilities for IOBuffer #
##########################

# Replace bytes for a node at the current position in the IOBuffer. `size` is the current
# window for the node, i.e. the number of bytes until the next node starts. If `size` is
# smaller or larger than the length of `bytes` this method will shift the bytes for
# remaining nodes to the left or right. Return number of written bytes.
function replace_bytes!(io::IOBuffer, bytes::Union{String, AbstractVector{UInt8}}, size::Int)
    pos = position(io)
    nb = (bytes isa AbstractVector{UInt8} ? length(bytes) : sizeof(bytes))
    if nb == size
        nw = write(io, bytes)
        @assert nb == nw
    else
        backup = IOBuffer() # TODO: global const (with lock)?
        seek(io, pos + size)
        @assert position(io) == pos + size
        nb_written_to_backup = write(backup, io)
        seek(io, pos)
        @assert position(io) == pos
        nw = write(io, bytes)
        @assert nb == nw
        nb_read_from_backup = write(io, seekstart(backup))
        @assert nb_written_to_backup == nb_read_from_backup
        truncate(io, position(io))
    end
    seek(io, pos)
    @assert position(io) == pos
    return nb
end

replace_bytes!(io::IOBuffer, bytes::Union{String, AbstractVector{UInt8}}, size::Integer) =
    replace_bytes!(io, bytes, Int(size))
