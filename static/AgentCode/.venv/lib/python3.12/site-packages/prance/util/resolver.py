"""JSON ``$ref`` resolver with structural sharing.

Resolving ``$ref`` pointers replaces each reference node with the
referenced subtree.  A naive approach deep-copies every resolved
target, which makes resolution O(N^2) for chains of references.

This module instead uses **structural sharing**: the resolved value
for each unique ``(URL, JSON-pointer)`` pair is cached and the
*same Python object* is inserted at every site that references it.
This makes resolution O(N) — each target is resolved and copied
exactly once, regardless of how many places reference it.

Resolution is split into two fully iterative phases so that
arbitrarily deep ``$ref`` chains and high ``recursion_limit``
values cannot overflow Python's call stack:

1. **Discovery** — walk the spec, collect every ``$ref`` site and
   the dependency graph between targets.  Cycle detection happens
   here via a DFS *visiting* set.
2. **Resolution** — process targets in reverse-topological order
   (leaves first).  Each target's dependencies are already resolved,
   so substitution is a single-pass replacement.  Recursive targets
   (those involved in cycles) are unrolled ``recursion_limit`` times
   inside-out, with no recursion.

.. rubric:: Implications for consumers

**Safe without changes**

* Serialising the spec to JSON / YAML — identical subtrees simply
  get written out multiple times.
* Read-only traversal and validation.
* Any code that does not mutate the resolved spec in place.

**Requires care**

If you mutate a resolved subtree (e.g. inject vendor extensions,
strip fields for code generation), every other location that
shares the same object will see those changes.  Two strategies
exist:

1. **Opt-in deep copy** — pass ``materialize=True`` to
   ``resolve_references()`` (or set ``materialize: True`` in the
   parser options).  This performs a single full deep copy *after*
   resolution, breaking all sharing.

2. **Copy-on-write at the call site** — deep-copy only the parts
   you intend to mutate.  This is more efficient when you only
   touch a small part of a large spec.
"""

__author__ = "Jens Finkhaeuser"
__copyright__ = "Copyright (c) 2016-2018 Jens Finkhaeuser"
__license__ = "MIT"
__all__ = ()

import copy

import prance.util.url as _url

try:
    import orjson as _orjson
except ImportError:
    _orjson = None


def _deepcopy_specs(value):
    if _orjson is not None:
        try:
            return _orjson.loads(_orjson.dumps(value))
        except TypeError:
            pass
    return copy.deepcopy(value)


def _replace_at_path(obj: dict | list, path: tuple, value: object) -> None:
    """Navigate to path's parent in obj and replace the final key with value."""
    for key in path[:-1]:
        obj = obj[key] if isinstance(obj, dict) else obj[int(key)]
    final = path[-1]
    if isinstance(obj, dict):
        obj[final] = value
    else:
        obj[int(final)] = value


#: Resolve internal references
RESOLVE_INTERNAL = 2**1
#: Resolve references to HTTP external files.
RESOLVE_HTTP = 2**2
#: Resolve references to local files.
RESOLVE_FILES = 2**3

#: Copy the schema changing the reference.
TRANSLATE_EXTERNAL = 0
#: Replace the reference with inlined schema.
TRANSLATE_DEFAULT = 1

#: Default, resole all references.
RESOLVE_ALL = RESOLVE_INTERNAL | RESOLVE_HTTP | RESOLVE_FILES


class _KeepRef:
    """Sentinel returned by recursion-limit handlers to leave the $ref in place."""

    __slots__ = ()


KEEP_REF = _KeepRef()


def default_reclimit_handler(limit, parsed_url, recursions=()):
    """Raise prance.util.url.ResolutionError."""
    path = []
    for rc in recursions:
        path.append("{}#/{}".format(rc[0], "/".join(rc[1])))
    path = "\n".join(path)

    raise _url.ResolutionError(
        "Recursion reached limit of %d trying to "
        'resolve "%s"!\n%s' % (limit, parsed_url.geturl(), path)
    )


def keep_ref_on_recursion(limit, parsed_url, recursions=()):
    """Leave the ``$ref`` in place when the recursion limit is reached."""
    return KEEP_REF


def permissive_object_on_recursion(limit, parsed_url, recursions=()):
    """Replace recursive ``$ref`` with a permissive object schema.

    The replacement allows any attributes and tags the original
    reference via the ``x-recursive-ref`` extension key.
    """
    return {
        "type": "object",
        "additionalProperties": True,
        "x-recursive-ref": parsed_url.geturl(),
    }


# -- Ref-key: a hashable identifier for a unique $ref target -----------
# Tuple of (url_resource_string, tuple_of_obj_path_parts).

_RefKey = tuple[str, tuple[str, ...]]


class RefResolver:
    """Resolve JSON pointers/references in a spec by inlining."""

    def __init__(self, specs, url=None, **options):
        """
        Construct a JSON reference resolver.

        The resolved specs are in the `specs` member after a call to
        `resolve_references` has been made.

        If a URL is given, it is used as a base for calculating the absolute
        URL of relative file references.

        :param dict specs: The parsed specs in which to resolve any references.
        :param str url: [optional] The URL to base relative references on.
        :param dict reference_cache: [optional] Reference cache to use. When
            encountering references, nested RefResolvers are created, and this
            parameter is used by the RefResolver hierarchy to create only one
            resolver per unique URL.
            If you wish to use this optimization across distinct RefResolver
            instances, pass a dict here for the RefResolvers you create
            yourself. It's safe to ignore this parameter in other cases.
        :param int recursion_limit: [optional] set the limit on recursive
            references. The default is 1, indicating that an element may be
            referred to exactly once when resolving references. When the limit
            is reached, the recursion_limit_handler is invoked.
        :param callable recursion_limit_handler: [optional] A callable that
            gets invoked when the recursion_limit is reached. Defaults to
            raising ResolutionError. Receives the recursion_limit as the
            first parameter, and the parsed reference URL as the second. As
            the last parameter, it receives a tuple of references that have
            been detected as recursions.
        :param str encoding: [optional] The encoding to use. If not given,
            detect_encoding is used to determine the encoding.
        :param int resolve_types: [optional] Specify which types of references to
            resolve. Defaults to RESOLVE_ALL.
        :param int resolve_method: [optional] Specify whether to translate external
            references in components/schemas or dereference in place. Defaults
            to TRANSLATE_DEFAULT.
        :param bool strict: [optional] Whether to use strict mode or not; in
            lenient mode, malformed keys will be silently rewritten.
        """
        self.specs = _deepcopy_specs(specs)
        self.url = url

        self.__reclimit = options.get("recursion_limit", 1)
        self.__reclimit_handler = options.get(
            "recursion_limit_handler", default_reclimit_handler
        )
        self.__reference_cache = options.get("reference_cache", {})
        self.__resolve_types = options.get("resolve_types", RESOLVE_ALL)
        self.__resolve_method = options.get("resolve_method", TRANSLATE_DEFAULT)
        self.__encoding = options.get("encoding", None)
        self.__strict = options.get("strict", True)

        if self.url:
            self.parsed_url = _url.absurl(self.url)
            self._url_key = (_url.urlresource(self.parsed_url), self.__strict)

            # If we have a url, we want to add ourselves to the reference cache
            # - that creates a reference loop, but prevents child resolvers from
            # creating a new resolver for this url.
            if self.specs:
                self.__reference_cache[self._url_key] = self.specs
        else:
            self.parsed_url = self._url_key = None

        self.__soft_dereference_objs = {}

    # ------------------------------------------------------------------
    # Public entry point
    # ------------------------------------------------------------------

    def resolve_references(self, *, materialize: bool = False):
        """Resolve JSON pointers/references in the spec.

        After this call, ``self.specs`` contains the fully-resolved spec
        tree.  Resolved subtrees that originate from the same ``$ref``
        target are the **same Python object** (structural sharing).

        :param bool materialize: If ``True``, perform a final deep copy
            of the entire spec, producing an independent object tree where
            no two nodes share identity.  Use this when downstream code
            mutates the resolved spec in place — without it, mutating one
            shared subtree will affect every location that references the
            same target.  The default (``False``) is appropriate for
            serialization, validation, and read-only access.

        .. note::

            Structural sharing turns resolution from O(N^2) to O(N) for
            chained references, because each target is resolved and deep-
            copied exactly once.  Passing ``materialize=True`` adds one
            additional O(N) deep copy at the end, which is still
            dramatically faster than the old per-reference copying.
        """
        sites, targets, edges, back_edges = self._discover_refs(
            self.parsed_url, self.specs
        )

        resolved = self._resolve_targets(targets, edges, back_edges)

        self._apply_to_spec(sites, resolved)

        if self.__soft_dereference_objs:
            if "components" not in self.specs:
                self.specs["components"] = {}
            if "schemas" not in self.specs["components"]:
                self.specs["components"].update({"schemas": {}})
            self.specs["components"]["schemas"].update(self.__soft_dereference_objs)

        if materialize:
            self.specs = _deepcopy_specs(self.specs)

    # ------------------------------------------------------------------
    # Phase 1: Discovery
    # ------------------------------------------------------------------

    def _discover_refs(self, base_url, spec):
        """Walk the spec iteratively, building the full reference topology.

        Returns:
            sites: list of (path_in_spec, ref_key, ref_url, base_url)
                   for every $ref site in the top-level spec.
            targets: dict of ref_key -> raw (unresolved) value
            edges: dict of ref_key -> list of (item_path, dep_ref_key, dep_url)
                   within that target's raw value
            back_edges: set of (from_key, dep_key) pairs that form cycles
        """
        from .iterators import reference_iterator

        sites: list[tuple] = []
        targets: dict[_RefKey, object] = {}
        edges: dict[_RefKey, list[tuple]] = {}

        visited: set[_RefKey] = set()
        queue: list[tuple] = []

        # Step 1: find all $ref sites in the top-level spec
        for _, refstring, item_path in reference_iterator(spec):
            ref_url, obj_path = _url.split_url_reference(base_url, refstring)

            if self._skip_reference(base_url, ref_url):
                continue

            ref_key: _RefKey = (_url.urlresource(ref_url), tuple(obj_path))
            sites.append((item_path, ref_key, ref_url, base_url))

            if ref_key not in visited:
                queue.append((ref_url, ref_key))
                visited.add(ref_key)

        # Step 2: BFS to discover all transitive targets
        while queue:
            d_ref_url, d_key = queue.pop()

            raw = self._fetch_ref_value(d_ref_url, list(d_key[1]))
            raw = _deepcopy_specs(raw)
            targets[d_key] = raw

            target_edges: list[tuple] = []
            for _, refstring, item_path in reference_iterator(raw):
                dep_url, dep_path = _url.split_url_reference(d_ref_url, refstring)

                if self._skip_reference(d_ref_url, dep_url):
                    continue

                dep_key: _RefKey = (_url.urlresource(dep_url), tuple(dep_path))
                target_edges.append((item_path, dep_key, dep_url))

                if dep_key not in visited:
                    queue.append((dep_url, dep_key))
                    visited.add(dep_key)

            edges[d_key] = target_edges

        # Step 3: detect cycles via DFS on the completed graph
        back_edges = self._find_back_edges(targets, edges)

        return sites, targets, edges, back_edges

    @staticmethod
    def _find_back_edges(targets, edges):
        """Find back-edges (cycles) in the dependency graph via DFS."""
        WHITE, GRAY, BLACK = 0, 1, 2
        color: dict[_RefKey, int] = {k: WHITE for k in targets}
        back_edges: set[tuple[_RefKey, _RefKey]] = set()

        for start in targets:
            if color[start] != WHITE:
                continue
            stack = [(start, 0)]
            while stack:
                node, idx = stack[-1]
                if idx == 0:
                    color[node] = GRAY

                node_edges = edges.get(node, [])
                if idx < len(node_edges):
                    stack[-1] = (node, idx + 1)
                    _, dep_key, _ = node_edges[idx]
                    if dep_key not in color:
                        continue
                    if color[dep_key] == WHITE:
                        stack.append((dep_key, 0))
                    elif color[dep_key] == GRAY:
                        back_edges.add((node, dep_key))
                else:
                    color[node] = BLACK
                    stack.pop()

        return back_edges

    # ------------------------------------------------------------------
    # Phase 2: Resolution
    # ------------------------------------------------------------------

    def _resolve_targets(self, targets, edges, back_edges):
        """Resolve all targets in topological order (leaves first).

        Returns a dict of ref_key -> resolved_value.
        """
        back_edge_set = back_edges
        ref_keys = list(targets.keys())

        # Build adjacency for topo-sort (excluding back-edges)
        forward_deps: dict[_RefKey, list[_RefKey]] = {}
        for rk in ref_keys:
            deps = []
            for _path, dep_key, _url_obj in edges.get(rk, []):
                if (rk, dep_key) not in back_edge_set:
                    deps.append(dep_key)
            forward_deps[rk] = deps

        order = self._topological_sort(ref_keys, forward_deps)

        resolved: dict[_RefKey, object] = {}

        for rk in order:
            raw = targets[rk]
            target_edges = edges.get(rk, [])

            # Separate forward and back (recursive) edges
            forward_changes: dict[tuple, object] = {}
            recursive_sites: list[tuple] = []

            for item_path, dep_key, dep_url in target_edges:
                is_back = (rk, dep_key) in back_edge_set

                if is_back:
                    recursive_sites.append((item_path, dep_key, dep_url))
                elif dep_key in resolved:
                    value = self._translate_value(dep_key, dep_url, resolved[dep_key])
                    forward_changes[item_path] = value

            # Apply forward substitutions
            raw = self._apply_changes(raw, forward_changes)

            # Handle recursive references via inside-out unrolling
            if recursive_sites:
                raw = self._unroll_recursive(rk, raw, recursive_sites, resolved)

            resolved[rk] = raw

        return resolved

    def _unroll_recursive(self, rk, raw, recursive_sites, resolved):
        """Unroll recursive $ref targets inside-out up to recursion_limit.

        For each recursive site in *raw* that points back to a target
        in the cycle, build the value from the innermost level outward.
        """
        # Collect all distinct recursive target keys from the sites
        rec_dep_keys = {dep_key for _, dep_key, _ in recursive_sites}

        for dep_key in rec_dep_keys:
            dep_sites = [
                (ip, dk, du) for ip, dk, du in recursive_sites if dk == dep_key
            ]

            # Build the recursion chain for this specific dependency
            chain = self._build_recursion_chain(rk, dep_key, dep_sites, resolved)
            if chain is KEEP_REF:
                continue
            resolved[dep_key] = chain

            # Now substitute the chain into raw
            changes: dict[tuple, object] = {}
            for item_path, _dk, dep_url in dep_sites:
                value = self._translate_value(dep_key, dep_url, chain)
                changes[item_path] = value
            raw = self._apply_changes(raw, changes)

        return raw

    def _build_recursion_chain(self, parent_key, dep_key, dep_sites, resolved):
        """Build an inside-out unrolled chain for a recursive target.

        Starting from the handler's return value at the limit, wraps
        successive copies of the raw target around it, producing a
        nesting depth equal to recursion_limit.
        """
        from .iterators import reference_iterator

        # Start with the handler's return at the limit.  We need a
        # parsed URL for the handler — use the first site's dep_url.
        dep_url = dep_sites[0][2]

        # Build the recursions tuple the handler expects
        recursions = tuple((parent_key, dep_key) * (self.__reclimit + 1))

        handler_value = self.__reclimit_handler(self.__reclimit, dep_url, recursions)
        if isinstance(handler_value, _KeepRef):
            return KEEP_REF

        # We need the raw template for the dep_key target.  If dep_key
        # is the same as parent_key (self-reference), we need to re-fetch
        # because our copy of raw already has forward subs applied.
        dep_raw = self._fetch_ref_value(dep_url, list(dep_key[1]))

        # Find which sites inside dep_raw point back to dep_key (the cycle)
        dep_raw_rec_sites: list[tuple] = []
        for _, refstring, item_path in reference_iterator(dep_raw):
            ref_url_parsed, obj_path = _url.split_url_reference(dep_url, refstring)
            if self._skip_reference(dep_url, ref_url_parsed):
                continue
            rk2: _RefKey = (_url.urlresource(ref_url_parsed), tuple(obj_path))
            if rk2 == dep_key:
                dep_raw_rec_sites.append((item_path, rk2, ref_url_parsed))

        # Also find forward (non-recursive) edges in dep_raw
        dep_raw_fwd: list[tuple] = []
        for _, refstring, item_path in reference_iterator(dep_raw):
            ref_url_parsed, obj_path = _url.split_url_reference(dep_url, refstring)
            if self._skip_reference(dep_url, ref_url_parsed):
                continue
            rk2 = (_url.urlresource(ref_url_parsed), tuple(obj_path))
            if rk2 != dep_key and rk2 in resolved:
                dep_raw_fwd.append((item_path, rk2, ref_url_parsed))

        # Build inside-out: level 0 is the handler value, then wrap.
        # reclimit=1 means one encounter allowed before the handler fires,
        # so 0 wrapping iterations (chain = handler value).
        current = handler_value
        for _level in range(self.__reclimit - 1):
            layer = _deepcopy_specs(dep_raw)

            # Apply forward deps into this layer
            fwd_changes: dict[tuple, object] = {}
            for item_path, fwd_key, fwd_url in dep_raw_fwd:
                fwd_changes[item_path] = self._translate_value(
                    fwd_key, fwd_url, resolved[fwd_key]
                )
            layer = self._apply_changes(layer, fwd_changes)

            # Substitute current (the inner level) into the recursive sites
            rec_changes: dict[tuple, object] = {}
            for item_path, _rk2, rec_url in dep_raw_rec_sites:
                rec_changes[item_path] = current
            layer = self._apply_changes(layer, rec_changes)

            current = layer

        return current

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _translate_value(self, ref_key, ref_url, resolved_value):
        """Wrap resolved_value for TRANSLATE_EXTERNAL if needed."""
        translate = (self.__resolve_method == TRANSLATE_EXTERNAL) and (
            self.parsed_url.path != ref_url.path
        )
        if translate:
            dref_url = self._collect_soft_refs(
                ref_url, list(ref_key[1]), resolved_value
            )
            return {"$ref": "#/components/schemas/" + dref_url}
        return resolved_value

    def _apply_changes(self, partial, changes):
        """Apply a dict of {path: value} substitutions, shortest-path-first."""
        if not changes:
            return partial
        paths = sorted(changes.keys(), key=len)
        for path in paths:
            value = changes[path]
            if len(path) == 0:
                partial = value
            else:
                _replace_at_path(partial, path, value)
        return partial

    def _apply_to_spec(self, sites, resolved):
        """Apply all resolved values into self.specs (single pass)."""
        changes: dict[tuple, object] = {}
        for item_path, ref_key, ref_url, base_url in sites:
            if ref_key in resolved:
                value = self._translate_value(ref_key, ref_url, resolved[ref_key])
                changes[item_path] = value
        self.specs = self._apply_changes(self.specs, changes)

    @staticmethod
    def _topological_sort(
        keys: list[_RefKey],
        deps: dict[_RefKey, list[_RefKey]],
    ) -> list[_RefKey]:
        """Kahn's algorithm — returns keys in dependency-first order."""
        from collections import deque

        key_set = set(keys)
        in_degree: dict[_RefKey, int] = {k: 0 for k in keys}
        for k in keys:
            for d in deps.get(k, []):
                if d in key_set:
                    in_degree[k] = in_degree.get(k, 0) + 1

        # Reverse adjacency: dep -> list of dependents
        reverse: dict[_RefKey, list[_RefKey]] = {k: [] for k in keys}
        for k in keys:
            for d in deps.get(k, []):
                if d in key_set:
                    reverse.setdefault(d, []).append(k)

        queue = deque(k for k in keys if in_degree[k] == 0)
        order: list[_RefKey] = []
        while queue:
            node = queue.popleft()
            order.append(node)
            for dependent in reverse.get(node, []):
                in_degree[dependent] -= 1
                if in_degree[dependent] == 0:
                    queue.append(dependent)

        # Any remaining keys not in order have circular deps (handled
        # by back_edges); append them at the end.
        if len(order) < len(keys):
            remaining = [k for k in keys if k not in set(order)]
            order.extend(remaining)

        return order

    def _collect_soft_refs(self, ref_url, item_path, value):
        """
        Return a portion of the dereferenced url for TRANSLATE_EXTERNAL mode.

        format - ref-url_obj-path
        """
        dref_url = ref_url.path.split("/")[-1] + "_" + "_".join(item_path[1:])
        self.__soft_dereference_objs[dref_url] = value
        return dref_url

    def _skip_reference(self, base_url, ref_url):
        """Return whether the URL should not be dereferenced."""
        if ref_url.scheme.startswith("http"):
            return (self.__resolve_types & RESOLVE_HTTP) == 0
        elif ref_url.scheme == "file" or ref_url.scheme == "python":
            # Internal references
            if base_url.path == ref_url.path:
                return (self.__resolve_types & RESOLVE_INTERNAL) == 0
            # Local files
            return (self.__resolve_types & RESOLVE_FILES) == 0
        else:
            from urllib.parse import urlunparse

            raise ValueError(
                "Scheme {!r} is not recognized in reference URL: {}".format(
                    ref_url.scheme, urlunparse(ref_url)
                )
            )

    def _fetch_ref_value(self, ref_url, obj_path):
        """Fetch and extract the raw (unresolved) value for a ``$ref`` target."""
        contents = _url.fetch_url(
            ref_url, self.__reference_cache, self.__encoding, self.__strict
        )
        if len(obj_path) == 0:
            return contents

        from prance.util.path import path_get

        try:
            return path_get(contents, obj_path)
        except (KeyError, IndexError, TypeError) as ex:
            raise _url.ResolutionError(
                f'Cannot resolve reference "{ref_url.geturl()}": {str(ex)}'
            )
