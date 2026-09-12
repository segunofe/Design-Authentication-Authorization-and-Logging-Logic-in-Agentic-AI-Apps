"""This submodule contains specialty iterators over specs."""

__author__ = "Jens Finkhaeuser"
__copyright__ = "Copyright (c) 2016-2018 Jens Finkhaeuser"
__license__ = "MIT"
__all__ = ()


def item_iterator(value, path=()):
    """
    Return item iterator over the a nested dict- or list-like object.

    Returns each item value as the second item to unpack, and a tuple path to the
    item as the first value - in that, it behaves much like viewitems(). For list
    like values, the path is made up of numeric indices.

    Given a spec such as this::

      spec = {
        'foo': 42,
        'bar': {
          'some': 'dict',
        },
        'baz': [
          { 1: 2 },
          { 3: 4 },
        ]
      }

    Here, (parts of) the yielded values would be:

      ======== =============
      item     path
      ======== =============
      [...]    ('baz',)
      { 1: 2 } ('baz', 0)
      2        ('baz', 0, 1)
      ======== =============

    :param dict/list value: The specifications to iterate over.
    :return: An iterator over all items in the value.
    :rtype: iterator
    """
    # Yield the top-level object, always
    yield path, value

    from collections.abc import Mapping, Sequence

    # For dict and list like objects, we also need to yield each item
    # recursively.
    if isinstance(value, Mapping):
        for key, item in value.items():
            yield from item_iterator(item, path + (key,))
    elif isinstance(value, Sequence) and not isinstance(value, str):
        for idx, item in enumerate(value):
            yield from item_iterator(item, path + (idx,))


def reference_iterator(specs, path=()):
    """
    Iterate through the given specs, returning only references.

    Uses ``isinstance`` so that dict/list subclasses (e.g. ruamel.yaml's
    ``CommentedMap``/``CommentedSeq``) are handled correctly.

    The iterator returns three values:
      - The key, mimicking the behaviour of other iterators, although
        it will always equal '$ref'
      - The value
      - The path to the item. This is a tuple of all the item's ancestors,
        in sequence, so that you can reasonably easily find the containing
        item. It does not include the final '$ref' key.

    :param dict specs: The specifications to iterate over.
    :return: An iterator over all references in the specs.
    :rtype: iterator
    """
    stack = [(path, specs)]
    while stack:
        current_path, value = stack.pop()
        if isinstance(value, dict):
            children = []
            for key, item in value.items():
                if key == "$ref":
                    yield "$ref", item, current_path
                elif isinstance(item, (dict, list, tuple)):
                    children.append((current_path + (key,), item))
            stack.extend(reversed(children))
        elif isinstance(value, (list, tuple)):
            children = []
            for idx, item in enumerate(value):
                if isinstance(item, (dict, list, tuple)):
                    children.append((current_path + (idx,), item))
            stack.extend(reversed(children))
