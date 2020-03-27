// Author: Pavitra Roychoudhury
Channel.fromPath("test/manifest.csv").splitCsv(header:true).into{samples; for_prereporting}
reference_fa = file("refs/NC_045512.fasta")
reference_gb = file("refs/NC_045512.gb")

// TODO: make separate pipeline for reference creation, store in s3
process bowtie_index {
    container "quay.io/biocontainers/bowtie2:2.4.1--py38he513fc3_0"

    label "med_cpu_mem"

    input:
        file(ref) from reference_fa

    output:
        file('*.bt2') into bowtie_ref

    """
    bowtie2-build --threads ${task.cpus} ${ref} reference
    """
}

process bwa_index {
    container "quay.io/biocontainers/bwa:0.7.17--hed695b0_7"

    label "med_cpu_mem"

    input:
        file(ref) from reference_fa

    output:
        file('*') into bwa_ref

    """
    bwa index ${ref}
    """
}

process prokka_index {
    container "quay.io/biocontainers/prokka:1.14.6--pl526_0"

    label "med_cpu_mem"

    input:
        file("reference.gb") from reference_gb

    output:
        file("proteins.faa") into prokka_ref

    """
    prokka-genbank_to_fasta_db reference.gb > proteins.faa
    """
}

// FastQC report on raw reads
process fastqc_prereport  {
    container "quay.io/biocontainers/fastqc:0.11.9--0"

    label "fastqc_mem"

    input:
        file(fastqs) from for_prereporting.collect{ file(it["fastq"]) }

    output:
       file("*") into reports

    publishDir params.output + "/fastqc_reports_raw/", overwrite: true

    """
    zcat ${fastqs} | fastqc --threads ${task.cpus} stdin:report
    """
}

// Adapter trimming with bbduk
process trimming {
    container "quay.io/biocontainers/bbmap:38.79--h516909a_0"

    label "med_cpu_mem"

    input:
        tuple(val(sample), file(fastq)) from samples.map{ [ it["sample"], file(it["fastq"]) ] }

    output:
        tuple(val(sample), file("trimmed.fastq.gz")) into (preprocessed, for_reference_mapping)
        file("trimmed.fastq.gz") into for_consensus_mapping

    // bbduk --help: When piping interleaving must be explicitly stated: int=f unpaired, int=t for paired
    """
    bbduk.sh in=${fastq} out=stdout.fq hdist=2 interleaved=f k=21 ktrim=r mink=4 ref=adapters,artifacts threads=${task.cpus} |
    bbduk.sh in=stdin.fq out=stdout.fq hdist=2 interleaved=f k=21 ktrim=l mink=4 ref=adapters,artifacts threads=${task.cpus} |
    bbduk.sh in=stdin.fq out=trimmed.fastq.gz interleaved=f maq=10 minlen=20 qtrim=rl trimq=20 threads=${task.cpus}
    """
}

// Map reads to reference
process map_to_ref {
    container "quay.io/biocontainers/bowtie2:2.4.1--py38he513fc3_0"

    label "med_cpu_mem"

    input:
        tuple(val(sample), file(fastq)) from for_reference_mapping
        file('') from bowtie_ref

    output:
        tuple(val(sample), file("alignment.sam")) into sam

    """
    bowtie2 --threads ${task.cpus} -x reference -U ${fastq} -S alignment.sam
    """
}

process sam_to_bam {
    container "quay.io/biocontainers/samtools:1.10--h9402c20_2"

    label "med_cpu_mem"

    input:
        tuple(val(sample), file("alignment.sam")) from sam

    output:
        tuple(val(sample), file("sorted.bam")) into sorted

    // samtools --help: -m INT Set maximum memory per thread; suffix K/M/G recognized [768M]
    """
    samtools view --threads ${task.cpus} -b alignment.sam |
    samtools sort --threads ${task.cpus} -o sorted.bam
    """
}

// Use bbduk to filter viral reads
process filter {
    container "quay.io/biocontainers/bbmap:38.79--h516909a_0"

    label "med_cpu_mem"

    input:
        tuple(val(sample), file(fastq)) from preprocessed
        file(ref) from reference_fa

    output:
        tuple(val(sample), file("${sample}_matched.fastq.gz")) into filtered
        file("${sample}_matched.fastq.gz") into for_filtered_reporting
        file("${sample}_unmatched.fastq.gz")
        file("${sample}_stats_filtering.txt")

    publishDir params.output + "/filtered_fastq/", overwrite: true

    """
    bbduk.sh in=${fastq} out=${sample}_unmatched.fastq.gz outm=${sample}_matched.fastq.gz ref=${ref} hdist=2 k=31 stats=${sample}_stats_filtering.txt --threads=${task.cpus}
    """
}

// FastQC report on processed reads
process fastqc_processed_report  {
    container "quay.io/biocontainers/fastqc:0.11.9--0"

    label "fastqc_mem"

    input:
        file(fastqs) from for_filtered_reporting.collect()

    output:
       file("*")

    publishDir params.output + "/fastqc_reports_preprocessed/", overwrite: true

    """
    zcat ${fastqs} | fastqc --threads ${task.cpus} stdin:report
    """
}

// Assemble with SPAdes
// FIXME: fix error here with some samples..
process assemble {
    container "quay.io/biocontainers/spades:3.14.0--h2d02072_0"

    label "med_cpu_mem"

    input:
        tuple(val(sample), file(fastq)) from filtered

    output:
        file("scaffolds.fasta") into scaffolds

    """
    spades.py --careful --memory ${task.memory.toGiga() * 8} --threads ${task.cpus} -s ${fastq} -o .
    """
}

// lifted scaffold filtering out of hcov_make_seq.R
process filter_scaffolds {
    // TODO: use public bioconductor docker image?
    container 'hcov19-r-deps:latest'

    input:
        file(scaffolds) from scaffolds

    output:
        file('filtered_scaffolds.fasta') into filtered_scaffolds

    //TODO: min_len and min_cov as params?

    """
    filter_scaffolds.R ${scaffolds} filtered_scaffolds.fasta 200 5
    """
}

// lifted scaffold alignment out of hcov_make_seq.R
process align_contigs {
    // TODO: consolidate this and next step in container with bwa and samtools

    container 'quay.io/biocontainers/bwa:0.7.17--hed695b0_7'

    input:
        file(scaffold) from filtered_scaffolds
        file(ref_fa) from reference_fa
        file('') from bwa_ref

    output:
        file('filtered_scaffolds.sam') into aligned_contigs

    """
    bwa mem ${ref_fa} ${scaffold} > filtered_scaffolds.sam
    """
}

process scaffold_sam_to_bam {

    container 'quay.io/biocontainers/samtools:1.10--h9402c20_2'

    input:
        file(contig_sam) from aligned_contigs
        file(ref_fa) from reference_fa

    output:
        file('filtered_scaffolds_sorted.bam') into filtered_scaffold_bam

    // samtools --help: -m INT Set maximum memory per thread; suffix K/M/G recognized [768M]
    """
    samtools view -bh -@ ${task.cpus} -o filtered_scaffolds.bam \
       ${contig_sam} -T ${ref_fa}
    samtools sort -@ ${task.cpus} -o filtered_scaffolds_sorted.bam \
       filtered_scaffolds.bam
    """
}

process make_ref_from_assembly {
    container 'bioconductor/release_core2:R3.6.2_Bioc3.10'

    input:
        file(bam) from filtered_scaffold_bam
        file(ref_fa) from reference_fa

    output:
        file('scaffold_consensus.fasta') into consensus

    """
    make_ref_from_assembly.R ${bam} ${ref_fa} scaffold_consensus.fasta
    """
}

process bowtie_consensus_build {
    container "quay.io/biocontainers/bowtie2:2.4.1--py38he513fc3_0"

    label "med_cpu_mem"

    input:
        file("consensus.fasta") from consensus

    output:
        file("*.bt2") into consensus_build

    """
    bowtie2-build --threads ${task.cpus} consensus.fasta reference
    """
}

process map_to_consensus {
    container "quay.io/biocontainers/bowtie2:2.4.1--py38he513fc3_0"

    label "med_cpu_mem"

    input:
        file(fastq) from for_consensus_mapping
        file("") from consensus_build

    output:
        file("alignment.sam") into remap_sam

    """
    bowtie2 --threads ${task.cpus} -x reference -U ${fastq} -S alignment.sam
    """
}

process consensus_sam_to_bam {
    container "quay.io/biocontainers/samtools:1.10--h9402c20_2"

    label "med_cpu_mem"

    input:
        file("alignment.sam") from remap_sam

    output:
        file("remap_sorted.bam") into remap_sorted

    // samtools --help: -m INT Set maximum memory per thread; suffix K/M/G recognized [768M]
    """
    samtools view --threads ${task.cpus} -b alignment.sam |
    samtools sort --threads ${task.cpus} -o remap_sorted.bam
    """
}

process final_consensus {
    container 'bioconductor/release_core2:R3.6.2_Bioc3.10'

    label "med_cpu_mem"

    input:
        file(remapped_bam) from remap_sorted
        tuple(val(sample), file(mapped_bam)) from sorted

    output:
        tuple(val(sample), file('final_consensus.fasta')) into final_cons
        file('mapping_stats.csv') into mapping_stats

    publishDir params.output, overwrite: true

    // TODO: inject sample name -- see val(sample) ^^
    // FIXME: final_cons seqname must be sample name for prokka genbank LOCUS

    """
    hcov_generate_consensus.R ${remapped_bam} ${mapped_bam} ${reference_fa} \
        final_consensus.fasta mapping_stats.csv
    """
}

// TODO: check if prokka needs contigs to be >20 chars long
process prokka_annnotations {
    container "quay.io/biocontainers/prokka:1.14.6--pl526_0"

    label "med_cpu_mem"

    input:
        tuple(val(sample), file(fasta)) from final_cons
        file(ref) from prokka_ref

    publishDir params.output, overwrite: true

    output:
        file("*")

    """
    prokka --cpus ${task.cpus} --kingdom "Viruses" --genus "Betacoronavirus" --usegenus --prefix ${sample} --proteins ${ref} ${fasta}
    """
}

// TODO: add ncbi genbank submissions manifest
