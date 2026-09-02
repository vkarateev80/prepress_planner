"""Верификация PDF-отчёта через PyMuPDF (fitz): извлечение текста.

Использование:
    python tool/verify_pdf.py <path-to.pdf>

Печатает число страниц и извлечённый текст каждой страницы.
"""
import sys

import fitz  # PyMuPDF


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: verify_pdf.py <file.pdf>", file=sys.stderr)
        sys.exit(2)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    path = sys.argv[1]
    doc = fitz.open(path)
    print(f"pages: {doc.page_count}")
    for i, page in enumerate(doc):
        text = page.get_text()
        print(f"--- page {i + 1} ({len(text)} chars) ---")
        print(text)


if __name__ == "__main__":
    main()
