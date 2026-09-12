"""This module contains code for accessing values in nested data structures."""

__author__ = "Jens Finkhaeuser"
__copyright__ = "Copyright (c) 2018 Jens Finkhaeuser"
__license__ = "MIT"
__all__ = ()


def _json_ref_escape(path):
    """JSON-reference escape object path."""
    path = str(path)  # Could be an int, etc.
    path = path.replace("~", "~0")
    path = path.replace("/", "~1")
    return path


def _str_path(path):
    """Stringify object path."""
    return "/" + "/".join([_json_ref_escape(p) for p in path])


def _step_get(obj, key, path_of_obj):
    """Descend one level into *obj* by *key*, raising on errors.

    Handles dict/list subclasses (e.g. ruamel.yaml CommentedMap/Seq)
    via ``isinstance``, and falls back to ABC checks for exotic types.
    """
    if isinstance(obj, dict):
        if key not in obj:
            raise KeyError(
                'Object at "{}" does not contain key: {}'.format(
                    _str_path(path_of_obj), key
                )
            )
        return obj[key]

    if isinstance(obj, (list, tuple)):
        try:
            idx = int(key)
        except (ValueError, TypeError):
            raise KeyError(
                'Sequence at "%s" needs integer indices only, but got: %s'
                % (_str_path(path_of_obj), key)
            )
        if idx < 0 or idx >= len(obj):
            raise IndexError(
                'Index out of bounds for sequence at "%s": %d'
                % (_str_path(path_of_obj), idx)
            )
        return obj[idx]

    from collections.abc import Mapping, Sequence

    if isinstance(obj, Mapping):
        if key not in obj:
            raise KeyError(
                'Object at "{}" does not contain key: {}'.format(
                    _str_path(path_of_obj), key
                )
            )
        return obj[key]

    if isinstance(obj, Sequence) and not isinstance(obj, str):
        try:
            idx = int(key)
        except (ValueError, TypeError):
            raise KeyError(
                'Sequence at "%s" needs integer indices only, but got: %s'
                % (_str_path(path_of_obj), key)
            )
        if idx < 0 or idx >= len(obj):
            raise IndexError(
                'Index out of bounds for sequence at "%s": %d'
                % (_str_path(path_of_obj), idx)
            )
        return obj[idx]

    raise TypeError(f"Cannot get anything from type {type(obj)}!")


def path_get(obj, path, defaultvalue=None, path_of_obj=()):
    """
    Retrieve the value from obj indicated by path.

    Like dict.get(), except:

      - Any Mapping or Sequence is supported.
      - Path is itself a Sequence; the first part is applied to the passed
        object, the second part to the value returned from this operation, and
        so forth recursively.

    :param mixed obj: The Sequence or Mapping from which to retrieve values.
    :param Sequence path: A Sequence of zero or more key/index elements.
    :param mixed defaultvalue: If the value at the path does not exist and this
      parameter is not None, it is returned. Otherwise an error is raised.
    """
    if path is None or len(path) == 0:
        return obj if obj is not None else defaultvalue

    for key in path:
        obj = _step_get(obj, key, path_of_obj)
        path_of_obj = path_of_obj + (key,)

    return obj if obj is not None else defaultvalue


def _fill_sequence(seq, index, path, path_index):
    """Fill list with None until *index* is reachable, then append typed placeholder."""
    if len(seq) > index:
        return
    while len(seq) < index:
        seq.append(None)
    next_index = path_index + 1
    if next_index < len(path) and isinstance(path[next_index], int):
        seq.append([])
    elif next_index >= len(path):
        seq.append(None)
    else:
        seq.append({})


def _step_set_descend(obj, key, path, i, create):
    """Descend one level into *obj* for path_set, creating intermediates if needed.

    Returns the child container to continue traversal into.
    """
    from collections.abc import Mapping, MutableMapping, Sequence, MutableSequence

    if isinstance(obj, dict):
        if key not in obj:
            if not create:
                raise KeyError(f'Key "{key}" not in Mapping!')
            next_key = path[i + 1]
            obj[key] = [] if isinstance(next_key, int) else {}
        return obj[key]

    if isinstance(obj, list):
        try:
            idx = int(key)
        except (ValueError, TypeError):
            raise KeyError("Sequences need integer indices only.")
        if create:
            _fill_sequence(obj, idx, path, i)
            if obj[idx] is None:
                next_key = path[i + 1]
                obj[idx] = [] if isinstance(next_key, int) else {}
        return obj[idx]

    if isinstance(obj, Mapping):
        if not isinstance(obj, MutableMapping):  # pragma: nocover
            raise TypeError(f"Mapping is not mutable: {type(obj)}")
        if key not in obj:
            if not create:
                raise KeyError(f'Key "{key}" not in Mapping!')
            next_key = path[i + 1]
            obj[key] = [] if isinstance(next_key, int) else {}
        return obj[key]

    if isinstance(obj, Sequence) and not isinstance(obj, str):
        if not isinstance(obj, MutableSequence):
            raise TypeError(f"Sequence is not mutable: {type(obj)}")
        try:
            idx = int(key)
        except (ValueError, TypeError):
            raise KeyError("Sequences need integer indices only.")
        if create:
            _fill_sequence(obj, idx, path, i)
        return obj[idx]

    raise TypeError(f"Cannot set anything on type {type(obj)}!")


def _step_set_final(obj, key, value, path, path_index, create):
    """Set the final key in *obj* to *value*."""
    from collections.abc import Mapping, MutableMapping, Sequence, MutableSequence

    if isinstance(obj, dict):
        if not create and key not in obj:
            raise KeyError(f'Key "{key}" not in Mapping!')
        obj[key] = value
        return

    if isinstance(obj, list):
        try:
            idx = int(key)
        except (ValueError, TypeError):
            raise KeyError("Sequences need integer indices only.")
        if create:
            _fill_sequence(obj, idx, path, path_index)
        obj[idx] = value
        return

    if isinstance(obj, Mapping):
        if not isinstance(obj, MutableMapping):  # pragma: nocover
            raise TypeError(f"Mapping is not mutable: {type(obj)}")
        if not create and key not in obj:
            raise KeyError(f'Key "{key}" not in Mapping!')
        obj[key] = value
        return

    if isinstance(obj, Sequence) and not isinstance(obj, str):
        if not isinstance(obj, MutableSequence):
            raise TypeError(f"Sequence is not mutable: {type(obj)}")
        try:
            idx = int(key)
        except (ValueError, TypeError):
            raise KeyError("Sequences need integer indices only.")
        if create:
            _fill_sequence(obj, idx, path, path_index)
        obj[idx] = value
        return

    raise TypeError(f"Cannot set anything on type {type(obj)}!")


def path_set(obj, path, value, **options):
    """
    Set the value in obj indicated by path.

    Setter anologous to path_get() above.

    As setting values is a write operation, this function optionally creates
    intermediate objects to ensure all elements of path can be dereferenced.

    :param mixed obj: The Sequence or Mapping from which to retrieve values.
    :param Sequence path: A Sequence of zero or more key/index elements.
    :param mixed value: The value to set.
    :param bool create: [optional] Flag indicating whether to create
      intermediate values or not. Defaults to False.
    """
    create = options.get("create", False)

    if len(path) < 1:
        raise KeyError("Cannot set with an empty path!")

    root = obj
    last = len(path) - 1

    for i in range(last):
        obj = _step_set_descend(obj, path[i], path, i, create)

    _step_set_final(obj, path[last], value, path, last, create)
    return root
