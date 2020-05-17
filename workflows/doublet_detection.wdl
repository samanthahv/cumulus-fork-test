version 1.0

workflow doublet_detection {
    input {
        File? input_sample_sheet
        File? input_h5_file
        String output_directory
        String? sample_id

        # Prefix for mitochondrial genes. (default: "MT-")
        String? mito_prefix
        # Only keep cells with at least <min_genes> genes. (default: 500)
        Int? min_genes
        # Only keep cells with less than <max_genes> genes. (default: 6000)
        Int? max_genes
        # Only keep cells with at least <min_umis> UMIs. (default: 100)
        Int? min_umis
        # Only keep cells with less than <max_umis> UMIs. (default: 600,000)
        Int? max_umis
        # Only keep cells with percent mitochondrial genes less than <percent_mito>% of total counts. (default: 10.0)
        Float? percent_mito
        # Only assign genes to be robust that are expressed in at least <percent_cells>% of cells. (default: 0.05)
        Float? percent_cells
        # Random state for doublet simulation, approximate nearest neighbor search, and PCA/TruncatedSVD. (default: 0)
        Int? random_state
        # Number of principal components used to embed the transcriptomes prior to k-nearest-neighbor graph construction. (default: 30)
        Int? nPC
        
        String docker_registry = "cumulusprod"
        String config_version = "0.1"
        String scrublet_version = "0.2.1"
        # Google cloud zones, default to "us-central1-a us-central1-b us-central1-c us-central1-f us-east1-b us-east1-c us-east1-d us-west1-a us-west1-b us-west1-c"
        String zones = "us-central1-a us-central1-b us-central1-c us-central1-f us-east1-b us-east1-c us-east1-d us-west1-a us-west1-b us-west1-c"
        # Number of cpus per cumulus job
        Int num_cpu = 8
        # Memory size string
        String memory = "200G"
        # Total disk space
        Int disk_space = 100
        # Number of preemptible tries 
        Int preemptible = 2
    }

    if (defined(input_sample_sheet)) {
        call process_sample_sheet as Config {
            input:
                input_sample_sheet = select_first([input_sample_sheet]),
                docker_registry = docker_registry,
                config_version = config_version,
                zones = zones,
                preemptible = preemptible
        }

        if (Config.sample_ids[0] != '') {
            scatter (sample_id in Config.sample_ids) {
                call detect_doublets as DetectDoubletsScatter {
                    input:
                        sample_id = sample_id,
                        input_h5_file = Config.id2h5[sample_id],
                        output_directory = output_directory,
                        mito_prefix = mito_prefix,
                        min_genes = min_genes,
                        max_genes = max_genes,
                        min_umis = min_umis,
                        max_umis = max_umis,
                        percent_mito = percent_mito,
                        percent_cells = percent_cells,
                        random_state = random_state,
                        nPC = nPC,
                        docker_registry = docker_registry,
                        scrublet_version = scrublet_version,
                        zones = zones,
                        num_cpu = num_cpu,
                        memory = memory,
                        disk_space = disk_space,
                        preemptible = preemptible
                }
            }
        }
    }

    if (!defined(input_sample_sheet) && defined(input_h5_file)) {
        call detect_doublets as DetectDoublets {
            input:
                sample_id = select_first([sample_id]),
                input_h5_file = select_first([input_h5_file]),
                output_directory = output_directory,
                mito_prefix = mito_prefix,
                min_genes = min_genes,
                max_genes = max_genes,
                min_umis = min_umis,
                max_umis = max_umis,
                percent_mito = percent_mito,
                percent_cells = percent_cells,
                random_state = random_state,
                nPC = nPC,
                docker_registry = docker_registry,
                scrublet_version = scrublet_version,
                zones = zones,
                num_cpu = num_cpu,
                memory = memory,
                disk_space = disk_space,
                preemptible = preemptible
        }
    }


    output {
        File? output_scored_zarr = DetectDoublets.output_scored_zarr
        Array[File]? output_scored_zarr_list = DetectDoubletsScatter.output_scored_zarr
    }
}

task process_sample_sheet {
    input {
        File input_sample_sheet
        String docker_registry
        String config_version
        String zones
        Int preemptible
    }

    command {
        set -e
        export TMPDIR=/tmp

        python <<CODE
        import re, sys
        import pandas as pd

        df = pd.read_csv('~{input_sample_sheet}', header = 0, dtype = str, index_col = False)
        for c in df.columns:
            df[c] = df[c].str.strip()
        regex_pat = re.compile('[^a-zA-Z0-9_-]')
        if any(df['Sample'].str.contains(regex_pat)):
            print('Sample must contain only alphanumeric characters, hyphens, and underscores.')
            print('Examples of common characters that are not allowed are the space character and the following: ?()[]/\=+<>:;"\',*^| &')
            sys.exit(1)

        with open('sample_ids.txt', 'w') as fo_ids, open('id2h5.txt', 'w') as fo_h5s:
            for idx, row in df.iterrows():
                fo_ids.write(row['Sample'] + '\n')
                fo_h5s.write(row['Sample'] + '\t' + row['Location'] + '\n')
        CODE
    }

    output {
        Array[String] sample_ids = read_lines('sample_ids.txt')
        Map[String, String] id2h5 = read_map('id2h5.txt')
    }

    runtime {
        docker: "~{docker_registry}/config:~{config_version}"
        zones: zones
        preemptible: "~{preemptible}"
    }
}

task detect_doublets {
    input {
        String sample_id
        File input_h5_file
        String output_directory
        String? mito_prefix
        Int? min_genes
        Int? max_genes
        Int? min_umis
        Int? max_umis
        Float? percent_mito
        Float? percent_cells
        Int? random_state
        Int? nPC

        String docker_registry
        String scrublet_version
        String zones
        Int num_cpu
        String memory
        Int disk_space
        Int preemptible
    }

    command {
        set -e
        export TMPDIR=/tmp
        monitor_script.sh > monitoring.log &

        python <<CODE
        import pegasusio as io
        import scrublet as scr

        kwargs = dict()
        if '~{mito_prefix}' is not '':
            kwargs['mito_prefix'] = '~{mito_prefix}'
        if '~{min_genes}' is not '':
            kwargs['min_genes'] = int('~{min_genes}')
        if '~{max_genes}' is not '':
            kwargs['max_genes'] = int('~{max_genes}')
        if '~{min_umis}' is not '':
            kwargs['min_umis'] = int('~{min_umis}')
        if '~{max_umis}' is not '':
            kwargs['max_umis'] = int('~{max_umis}')
        if '~{percent_mito}' is not '':
            kwargs['percent_mito'] = float('~{percent_mito}')
        if '~{percent_cells}' is not '':
            kwargs['percent_cells'] = float('~{percent_cells}')

        data = io.read_input('~{input_h5_file}')
        io.qc_metrics(data, **kwargs)
        io.filter_data(data)

        kwargs = dict()
        if '~{random_state}' is not '':
            kwargs['random_state'] = int('~{random_state}')
        scrub = scr.Scrublet(data.X, **kwargs)

        kwargs = dict()
        if '~{nPC}' is not '':
            kwargs['nPC'] = int('~{nPC}')
        doublet_scores, predicted_doublets = scrub.scrub_doublets(**kwargs)

        data.obs['doublet_scores'] = doublet_scores
        io.write_output(data, '~{sample_id}_scored.zarr', zarr_zipstore = True)
        CODE

        mkdir result
        cp ~{sample_id}_scored.zarr result
        gsutil -q -m rsync -r result ~{output_directory}/~{sample_id}
        # mkdir -p ~{output_directory}/~{sample_id}
        # cp result/* ~{output_directory}/~{sample_id}
    }

    output {
        File output_scored_zarr = 'result/~{sample_id}_scored.zarr'
        File monitoringLog = "monitoring.log"
    }

    runtime {
        docker: "~{docker_registry}/scrublet:~{scrublet_version}"
        zones: zones
        memory: "~{memory}G"
        disks: "local-disk ~{disk_space} HDD"
        cpu: num_cpu
        preemptible: preemptible
    }
}
