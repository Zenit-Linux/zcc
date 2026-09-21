(defn fail [msg]
  (eprint "recipe.janet: " msg)
  (os/exit 1))

(def stage (os/getenv "ZPM_PACKAGE_STAGE_DIR"))
(when (or (nil? stage) (empty? stage))
  (fail "brak ZPM_PACKAGE_STAGE_DIR -- ten skrypt ma być uruchamiany przez `zpk build`"))

# zcc generuje kod wyłącznie dla x86_64-linux (patrz README, "Status").
# Nie etykietujemy binarki innej architektury jako x86_64.
(def arch (os/getenv "ZPM_PACKAGE_ARCH"))
(when (and arch (not (empty? arch)) (not= arch "x86_64"))
  (fail (string "zcc wspiera tylko x86_64, a zażądano '" arch "'")))

(def prebuilt (os/getenv "ZCC_PACKAGING_PREBUILT_BIN"))
(def use-prebuilt (and prebuilt (not (empty? prebuilt))))

(when (and (not use-prebuilt) (not= (os/arch) :x64))
  (fail (string "host to " (os/arch) ", a pakiet ma być x86_64 -- zbuduj binarkę na "
                "x86_64 i podaj ją przez ZCC_PACKAGING_PREBUILT_BIN")))

# packaging/ leży w <repo>/packaging -- katalog wyżej to korzeń repo.
(def repo-root (string (os/cwd) "/.."))
(def build-janet (string repo-root "/build.janet"))
(def janet-bin (or (dyn :executable) "janet"))

(defn drive [& args]
  (def code (os/execute [janet-bin build-janet ;args] :p))
  (unless (zero? code)
    (fail (string "build.janet " (string/join args " ") " zakończone kodem " code))))

(def bin-path
  (if use-prebuilt
    prebuilt
    (do (drive "release")
        (string repo-root "/bin/zcc"))))

(unless (= :file (os/stat bin-path :mode))
  (fail (string "nie znaleziono zbudowanej binarki: " bin-path)))

(drive "smoke" (string "--bin=" bin-path))
(drive "stage" stage (string "--bin=" bin-path))
