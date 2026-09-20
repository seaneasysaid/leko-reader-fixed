return {
    version = "0.16.0-fixed.3",
    catalog_version = 6,
    -- 9: native (leko://) sources are no longer graded "兼容运行时 / 需要
    -- JavaScript".  The bump makes startup re-seed the built-in definitions so
    -- an already-stored 书山聚合（原生） record picks up the corrected grade,
    -- reasons and capability label instead of keeping the old "需要 JavaScript".
    compatibility_version = 9,
    builtin_sources_version = 3,
}
