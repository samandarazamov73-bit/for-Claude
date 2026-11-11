"""Input limits shared by the web app, the API and the engine."""

MAX_FILE_BYTES = 30 * 1024 * 1024  # 30 MiB
MAX_UPLOAD_PIXELS = 33_554_432  # 32 MP accepted on upload (then reduced)
DEFAULT_MAX_PIXELS = 2_097_252  # working resolution used by default (~2 MP)
MAX_WORKING_PIXELS = 3_145_828  # largest working resolution (~3 MP)
MAX_BASE64_BYTES = 1024 * 1024  # base64 payloads are limited to 1 MB
MAX_PNG_EXPORT_PIXELS = 52_000_000
