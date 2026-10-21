import json, math, sys
def load(n):
    d = json.load(open(f"recs/{n}.json")); return d["frames"]
def low(f, s):
    return min(f[s+"Toe"][1], f[s+"Heel"][1])
def run(n, t0, t1):
    fr = load(n)
    g = min(min(low(f,"Right"), low(f,"Left")) for f in fr)
    sel = [f for f in fr if t0 <= f["t"] <= t1]
    out = {}
    T = sel[-1]["t"] - sel[0]["t"]
    downs = 0; slides = []; lifts = []
    hip = [f["parts"]["LowerTorso"][1] for f in sel]
    for s in ("Right", "Left"):
        was = None
        for i in range(1, len(sel)):
            a, b = sel[i-1], sel[i]
            la, lb = low(a, s)-g, low(b, s)-g
            on = lb < 0.1
            if was is not None and on and not was: downs += 1
            was = on
            if la < 0.1 and lb < 0.1:
                # slide of the lowest contact point (toe or heel, whichever is lower)
                key = s+"Toe" if b[s+"Toe"][1] <= b[s+"Heel"][1] else s+"Heel"
                dx = b[key][0]-a[key][0]; dz = b[key][2]-a[key][2]
                slides.append(math.hypot(dx, dz)/(b["t"]-a["t"]))
            lifts.append(lb)
    speed = sum(math.hypot(f["vel"][0], f["vel"][2]) for f in sel)/len(sel)
    slides.sort()
    out = dict(speed=round(speed,1), steps_per_s=round(downs/T,2),
               slide_med=round(slides[len(slides)//2],2) if slides else None,
               planted_share=round(len(slides)/max(1,2*(len(sel)-1)),2),
               foot_lift_max=round(max(lifts),2), hip_bob=round(max(hip)-min(hip),2), fps=round(len(sel)/T))
    return out
for arg in sys.argv[1:]:
    n, t0, t1 = arg.split(":")
    print(n, run(n, float(t0), float(t1)))
