EAR_OUTER = "M475 452 C475 382 517 330 571 330 C625 330 665 372 665 430 C665 480 637 506 621 530 C607 552 603 574 585 590 C567 606 541 606 525 594 C511 584 505 570 505 556"
EAR_INNER = "M527 452 C527 408 547 384 573 384 C599 384 617 404 617 432 C617 458 599 470 583 484"
EAR_TRAGUS = "M531 500 C547 500 559 512 559 528"
HEART = "M568 560 C520 526 452 484 452 420 C452 382 480 354 516 354 C540 354 558 368 568 386 C578 368 596 354 620 354 C656 354 684 382 684 420 C684 484 616 526 568 560 Z"

def svg(bg, ink):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect width="1024" height="1024" fill="{bg}"/>
  <g transform="translate(512 512) scale(1.18) translate(-525.5 -501)">
    <g fill="none" stroke="{ink}" stroke-width="40" stroke-linecap="round" stroke-linejoin="round">
      <path d="M384 196 H716 a36 36 0 0 1 36 36 V700 H384"/>
      <path d="M384 196 H379 a80 80 0 0 0 -80 80 V753"/>
      <line x1="384" y1="196" x2="384" y2="700"/>
      <path d="M752 700 V806 H352 a53 53 0 0 1 0 -106"/>
      <line x1="372" y1="753" x2="690" y2="753" stroke-width="24"/>
      <path d="{EAR_OUTER}" stroke-width="36"/>
      <path d="{EAR_INNER}" stroke-width="30"/>
      <path d="{EAR_TRAGUS}" stroke-width="28"/>
    </g>
  </g>
</svg>'''

open("light.svg", "w").write(svg("#EEF0F3", "#3346A8"))
open("dark.svg", "w").write(svg("#000000", "#E0A03A"))
