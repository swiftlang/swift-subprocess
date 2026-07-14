# ``OutputProtocol``

## Topics

### Creating an output

- ``string(limit:)``
- ``string(limit:encoding:)``
- ``bytes(limit:)``
- ``data(limit:)``
- ``fileDescriptor(_:closeAfterSpawningProcess:)``
- ``discarded``
- ``sequence``

### Accessing standard streams

- ``currentStandardOutput``
- ``currentStandardError``

### Implementing a custom output type

- ``OutputType``
- ``output(from:)``
- ``maxSize``
