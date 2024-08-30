#!/bin/bash
set -e

function init_variables() {
    print_help_if_needed $@
    script_dir=$(dirname $(realpath "$0"))
    #source $script_dir/../../../../../scripts/misc/checks_before_run.sh

    readonly FACES_IMAGES_DIR=/home/pi/exp/faces
    readonly MODEL_DIR=/home/pi/hailo-ai/models
    readonly TAPPAS_WORKSPACE="/home/pi/hailo-ai/tappas/tappas_v3.29.1"

    readonly RESOURCES_DIR="$TAPPAS_WORKSPACE/apps/h8/gstreamer/general/face_recognition/resources"
    readonly POSTPROCESS_DIR="$TAPPAS_WORKSPACE/apps/h8/gstreamer/libs/post_processes/"
    readonly APPS_LIBS_DIR="$TAPPAS_WORKSPACE/apps/h8/gstreamer/libs/apps/vms/"
    readonly CROPPER_SO="$POSTPROCESS_DIR/cropping_algorithms/libvms_croppers.so"
    
    # Face Detection
    readonly FACE_DETECTION_SO="/usr/lib/aarch64-linux-gnu/post_processes/libface_detection_post.so"

    # Face Alignment
    readonly FACE_ALIGN_SO="/usr/lib/aarch64-linux-gnu/apps/vms/libvms_face_align.so"
    
    # Face Recognition
    readonly RECOGNITION_POST_SO="/usr/lib/aarch64-linux-gnu/hailo/tappas/post-process/libface_recognition_post.so"
    readonly RECOGNITION_HEF_PATH="$MODEL_DIR/arcface_mobilefacenet.hef"
    readonly RECOGNITION_FUNCTION_NAME="arcface_nv12"

    # Face Detection and Landmarking
    readonly DEFAULT_HEF_PATH="$MODEL_DIR/retinaface_mobilenet_v1.hef"
    readonly FUNCTION_NAME="retinaface"

    detection_network="scrfd_10g"

    detection_hef=$DEFAULT_HEF_PATH
    detection_post=$FUNCTION_NAME

    recognition_hef="$MODEL_DIR/arcface_mobilefacenet.hef"
    recognition_post="arcface_nv12"

    hef_path="$MODEL_DIR/retinaface_mobilenet_v1.hef"

    video_format="RGB"
    network="scrfd_10g"
    hef_path="$MODEL_DIR/retinaface_mobilenet_v1.hef"

    video_sink_element=$([ "$XV_SUPPORTED" = "true" ] && echo "xvimagesink" || echo "ximagesink")
    additional_parameters=""
    print_gst_launch_only=false
    vdevice_key=1
    clean_local_gallery_file=false
    function_name=$FUNCTION_NAME
    local_gallery_file="/home/pi/exp/face_recognition_local_gallery_rgba.json"
}

function print_usage() {
    echo "Save face recognition local gallery - pipeline usage:"
    echo ""
    echo "Options:"
    echo "  --help                          Show this help"
    echo "  --clean                         Clean local gallery file enitrely"
    exit 0
}

function print_help_if_needed() {
    while test $# -gt 0; do
        if [ "$1" = "--help" ] || [ "$1" == "-h" ]; then
            print_usage
        fi

        shift
    done
}

function parse_args() {
    while test $# -gt 0; do
        if [ "$1" = "--help" ] || [ "$1" == "-h" ]; then
            print_usage
            exit 0
        elif [ $1 == "--clean" ]; then
            clean_local_gallery_file=true
            echo "Cleaning local gallery file"
        else
            echo "Received invalid argument: $1. See expected arguments below:"
            print_usage
            exit 1
        fi
        shift
    done
}

function main() {
    init_variables $@
    parse_args $@

    RECOGNITION_PIPELINE="hailocropper so-path=$CROPPER_SO function-name=face_recognition internal-offset=true name=cropper2 \
        hailoaggregator name=agg2 \
        cropper2. ! \
            queue name=bypess2_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
        agg2. \
        cropper2. ! \
            queue name=pre_face_align_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
            hailofilter so-path=$FACE_ALIGN_SO name=face_align_hailofilter use-gst-buffer=true qos=false ! \
            queue name=detector_pos_face_align_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
            hailonet hef-path=$RECOGNITION_HEF_PATH scheduling-algorithm=1 vdevice-key=$vdevice_key ! \
            queue name=recognition_post_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
            hailofilter so-path=$RECOGNITION_POST_SO name=face_recognition_hailofilter function-name=arcface_nv12 qos=false ! \
            queue name=recognition_pre_agg_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
        agg2. \
        agg2. "

    FACE_DETECTION_PIPELINE="hailonet hef-path=/home/pi/hailo-ai/models/retinaface_mobilenet_v1.hef scheduling-algorithm=1 vdevice-key=$vdevice_key ! \
        queue name=detector_post_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
        hailofilter so-path=$FACE_DETECTION_SO name=face_detection_hailofilter qos=false function_name=retinaface"

    FACE_TRACKER="hailotracker name=hailo_face_tracker class-id=-1 kalman-dist-thr=0.7 iou-thr=0.8 init-iou-thr=0.9 \
                    keep-new-frames=2 keep-tracked-frames=2 keep-lost-frames=2 keep-past-metadata=true qos=false"

    DETECTOR_PIPELINE="tee name=t hailomuxer name=hmux \
        t. ! \
            queue name=detector_bypass_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
        hmux. \
        t. ! \
            videoscale name=face_videoscale method=0 n-threads=6 add-borders=false qos=false ! \
            video/x-raw, pixel-aspect-ratio=1/1 ! \
            queue name=pre_face_detector_infer_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
            $FACE_DETECTION_PIPELINE ! \
            queue leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
        hmux. \
        hmux. "

    if [ "$print_gst_launch_only" = true ]; then
        exit 0
    fi

    if [ "$clean_local_gallery_file" = true ]; then
        rm -f $local_gallery_file
    fi

    skipped_names=()

    # Iterate over all png files in the directory
    for file in $FACES_IMAGES_DIR/*.png; do
        image_file=$file
        # Get image file name
        image_file_name="${image_file##*/}"
        # Remove the extension from the file name
        image_file_name="${image_file_name%.*}"
        # Set first letter to upper case
        image_file_name="${image_file_name^}"

        # Check if file $local_gallery_file already contains the name
        if grep -q $image_file_name $local_gallery_file; then
            skipped_names+=($image_file_name)
            continue
        fi

        pipeline="gst-launch-1.0 \
            multifilesrc location=$image_file loop=true num-buffers=50 ! decodebin ! \
            videoconvert n-threads=4 qos=false ! video/x-raw, format=$video_format, pixel-aspect-ratio=1/1 ! \
            queue name=pre_detector_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
            $DETECTOR_PIPELINE ! \
            queue name=pre_tracker_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
            $FACE_TRACKER ! \
            queue name=hailo_post_tracker_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
            $RECOGNITION_PIPELINE ! \
            queue name=hailo_pre_gallery_q leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
            hailogallery gallery-file-path=$local_gallery_file \
            save-local-gallery=true similarity-thr=.4 gallery-queue-size=20 class-id=-1 ! \
            queue name=pre_scale_q2 leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
            hailooverlay show-confidence=false name=overlay2 qos=false ! \
            queue name=hailo_post_draw leaky=no max-size-buffers=30 max-size-bytes=0 max-size-time=0 ! \
            videoconvert n-threads=8 qos=false name=display_videoconvert ! \
            queue name=hailo_display_q_0 leaky=no max_size_buffers=300 max-size-bytes=0 max-size-time=0 ! \
            autovideosink \
            ${additional_parameters}"

        echo "Running pipeline with file: $file"
        eval "${pipeline}"

        echo "$image_file_name added to the local gallery"
        # Replace Unknown1 in $local_gallery_file to the image name
        sed -i "s/Unknown1/$image_file_name/g" $local_gallery_file
        echo ""
    done

    echo ""
    if [ ${#skipped_names[@]} -gt 0 ]; then
        echo "Names: "
        for name in "${skipped_names[@]}"; do
            echo "$name"
        done
        echo ""

        echo "Already exists in the local gallery file $local_gallery_file"
        echo "You can run the script with --clean to clean the local gallery file enitrely"
        echo "Or edit the file manually, and run again"
        exit 1
    else
        echo "All images were added to the local gallery file $local_gallery_file successfully"
    fi
}

main $@
