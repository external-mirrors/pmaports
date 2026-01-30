# Configuration file for the Sphinx documentation builder.

import datetime
from pathlib import Path
import subprocess

project = "pmaports"
copyright = str(datetime.date.today().year) + ", postmarketOS contributors"
exclude_patterns = ["_build", "_out", "Thumbs.db", ".DS_Store", ".venv", "README.md"]

extensions = [
    "myst_parser",
    "sphinx.ext.autodoc",
    "sphinx.ext.autosummary",
    "sphinx.ext.doctest",
    "sphinxcontrib.autoprogram",
    "sphinxcontrib.jquery",
]
myst_enable_extensions = ["colon_fence"]

html_theme = "pmos"
html_theme_options = {
    # FIXME: This should be main once we rename the branch
    "source_edit_link": "https://gitlab.postmarketos.org/postmarketOS/pmaports/-/blob/master/docs/{filename}",
}

# Set the explicit title of the HTML output
html_title = "postmarketOS Packaging"


def run_dint_doc(app):
    with Path(__file__).parent.joinpath("deviceinfo-reference.md").open("w") as f:
        subprocess.call(["dint", "doc"], stdout=f)


def setup(app):
    app.connect("builder-inited", run_dint_doc)
