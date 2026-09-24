HEART = "M568 560 C520 526 452 484 452 420 C452 382 480 354 516 354 C540 354 558 368 568 386 C578 368 596 354 620 354 C656 354 684 382 684 420 C684 484 616 526 568 560 Z"

def svg(bg, ink, knot):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect width="1024" height="1024" fill="{bg}"/>
  <g transform="translate(-14 -52)">
    <g fill="none" stroke="{ink}" stroke-width="44" stroke-linecap="round" stroke-linejoin="round">
      <path d="M384 196 H716 a36 36 0 0 1 36 36 V700 H384"/>
      <path d="M384 196 H379 a80 80 0 0 0 -80 80 V753"/>
      <line x1="384" y1="196" x2="384" y2="700"/>
      <path d="M752 700 V806 H352 a53 53 0 0 1 0 -106"/>
      <line x1="372" y1="753" x2="690" y2="753" stroke-width="26"/>
      <path d="{HEART}" stroke-width="40"/>
      <rect x="462" y="606" width="212" height="34" rx="8" stroke-width="26"/>
    </g>
    <path d="M520 806 C520 850 498 872 504 904 C510 930 532 942 532 968" fill="none" stroke="{ink}" stroke-width="22" stroke-linecap="round"/>
    <circle cx="532" cy="976" r="28" fill="{knot}"/>
  </g>
</svg>'''

open("light.svg", "w").write(svg("#EEF0F3", "#3346A8", "#1C2130"))
open("dark.svg", "w").write(svg("#000000", "#E0A03A", "#F2C879"))
