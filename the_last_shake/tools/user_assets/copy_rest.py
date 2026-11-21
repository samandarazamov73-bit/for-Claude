"""Sets that needed no fix: copy them under the game material name (same map file names as the fixed ones)."""
import sys, os, glob, shutil
SRC, OUT = sys.argv[1], sys.argv[2]
MAP = {"M_Plaster_White": "Состаренная_штукатурка", "M_Ceiling_Paint": "Состаренная_штукатурка",
       "M_Linoleum_Brown": "Винтажныи_коричневыи_линолеум", "M_Linoleum_Parquet": "Старая_дубовая_паркетная",
       "M_Concrete_FacadePanel": "Текстура_состаренных_бетонных", "M_Concrete_Weathered": "Старая_потрескавшаяся",
       "M_Concrete_Trim": "Равномерная_бетонная", "M_Concrete_Paving": "Выветренная_бетонная",
       "M_Concrete_Interior": "Текстура_бетоннои_стены", "M_Roofing_Bitumen": "Состаренная_битумная"}
for mat, pref in MAP.items():
    d = glob.glob(os.path.join(SRC, pref + "*"))[0]; b = os.path.basename(d)
    os.makedirs(os.path.join(OUT, mat), exist_ok=True)
    for m in ("albedo", "normal_gl", "height", "roughness", "ao", "orm"):
        shutil.copy(os.path.join(d, f"{b}_{m}.png"), os.path.join(OUT, mat, m + ".png"))
    print(mat, "<-", b)
