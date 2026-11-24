"""Write Gradle signing properties from environment; never print secrets."""
import os
from pathlib import Path
import sys


def escape(value):
    # Java Properties uses ISO-8859-1 and backslash escapes.
    result = []
    for char in value:
        if char in "\\ =:#!":
            result.append("\\" + char)
        elif ord(char) < 32 or ord(char) > 126:
            raw = char.encode("utf-16-be")
            result.extend("\\u" + raw[i:i+2].hex() for i in range(0, len(raw), 2))
        else:
            result.append(char)
    return "".join(result)


def main():
    values = {"storeFile": "sindre-release.jks",
              "storePassword": os.environ["STORE_PASSWORD"],
              "keyAlias": os.environ["KEY_ALIAS"],
              "keyPassword": os.environ["KEY_PASSWORD"]}
    path = Path(sys.argv[1])
    with path.open("x", encoding="ascii") as stream:
        for key, value in values.items():
            stream.write(f"{key}={escape(value)}\n")


if __name__ == "__main__":
    main()
