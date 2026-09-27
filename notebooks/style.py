"""Shared chart styling so notebook figures and deck figures match."""

from pathlib import Path

import matplotlib as mpl
import matplotlib.pyplot as plt

FIG_DIR = Path(__file__).resolve().parent.parent / "readout" / "figures"
FIG_DIR.mkdir(parents=True, exist_ok=True)

BLUE = "#2a78d6"      # primary series
ORANGE = "#eb6834"    # the one thing a chart is pointing at
AQUA = "#1baf7a"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#8c8b86"
GRID = "#e4e3df"
GREYS = ["#1f3b5c", "#4f6f94", "#8fa8c4", "#c9d6e4"]   # tiers 1-4, dark -> light
SALE = "#f6d7c8"

mpl.rcParams.update({
    "figure.dpi": 110,
    "savefig.dpi": 200,
    "font.size": 10,
    "font.family": "DejaVu Sans",
    "axes.edgecolor": GRID,
    "axes.labelcolor": INK_2,
    "axes.titlecolor": INK,
    "axes.titlesize": 11,
    "axes.titleweight": "bold",
    "axes.titlelocation": "left",
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.grid": True,
    "axes.grid.axis": "y",
    "grid.color": GRID,
    "grid.linewidth": 0.8,
    "xtick.color": INK_2,
    "ytick.color": INK_2,
    "legend.frameon": False,
    "lines.linewidth": 2,
})


def save(fig, name):
    fig.savefig(FIG_DIR / f"{name}.png", bbox_inches="tight", facecolor="white")
