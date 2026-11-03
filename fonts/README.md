# Pixel fonts bundled with jf_tracker

Nerd Fonts "Mono" builds, unchanged (files as released by Nerd Fonts,
https://github.com/ryanoasis/nerd-fonts). Install: options → look →
install bundled fonts (copies them into ~/Library/Fonts), or double-click a file.
Each font keeps its own licence — the texts are in `licenses/`.

| file | font | author | licence |
|---|---|---|---|
| BigBlueTermPlusNerdFontMono-Regular.ttf, BigBlueTerm437NerdFontMono-Regular.ttf | BigBlue Terminal | VileR, https://int10h.org (c) 2015 | CC BY-SA 4.0 — `licenses/BigBlueTerm.txt` |
| DepartureMonoNerdFontMono-Regular.otf | Departure Mono | Helena Zhang & Tobias Fried (c) 2024, https://departuremono.com | MIT — `licenses/DepartureMono-MIT.txt` |
| GohuFont11NerdFontMono-Regular.ttf, GohuFont14NerdFontMono-Regular.ttf | Gohufont | Hugo Chargois (c) 2010, http://font.gohu.org; TTF by Guilherme Maeda | WTFPL — `licenses/GohuFont.txt` |
| TerminessNerdFontMono-Regular.ttf | Terminus (as "Terminess": Reserved Font Name) | Dimitar Toshkov Zhekov (c) 2010 | SIL OFL 1.1 — `licenses/Terminus-OFL.txt` |
| ProggyCleanNerdFontMono-Regular.ttf | Proggy Clean | Tristan Grimmer (c) 2004-2005, https://github.com/bluescan/proggyfonts | MIT — `licenses/ProggyClean.txt` |
| ProFontIIxNerdFontMono-Regular.ttf | ProFont IIx | Tobias Jung, Carl Osterwald, Stephen C. Gilardi, Andrew Welch (c) 2014 | MIT — `licenses/ProFont.txt` |
| 3270NerdFontMono-Regular.ttf | IBM 3270 | Ricardo Banffy and the 3270font authors, https://github.com/rbanffy/3270font | BSD 3-Clause — `licenses/IBM3270.txt` |

Nerd Fonts patcher and its additions: MIT — `licenses/NerdFonts-MIT.txt`;
licences of the icon sets merged into every file: `licenses/NerdFonts-icon-licenses.md`.

The BigBlue Terminal files are shared under the same licence, CC BY-SA 4.0
(ShareAlike): keep this attribution when you pass them on.

Trimmed (3 Nov 2026): the Nerd Font icon glyphs (Private Use Area U+E000-F8FF and above U+F0000) are removed
with fonttools pyftsubset; every other character, the names and the hinting are kept. The tracker uses letters,
not icons, and the icons also covered the SMuFL music signs (U+E000...). Licences are unchanged (licenses/).
